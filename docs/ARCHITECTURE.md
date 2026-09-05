# Architecture

Read this once end to end. It follows a single request from a browser to the
database and back, naming every component it passes through. Once you can
narrate that path from memory, troubleshooting stops being guesswork — you can
ask "which hop is broken?" instead of "what is wrong?".

---

## The path of one request

```
Browser
  │  https://app.sawibowo.sandbox.devopsinstitute.id/api/timeline
  ▼
[1] Route53 ──────────── A-record (alias) → the ALB's DNS name
  ▼                      created by ExternalDNS from the Ingress annotation
[2] ALB (public subnets) TLS terminated using the ACM wildcard certificate
  │                      listener rules evaluated in PRIORITY ORDER:
  │                        10  /api/*  -> app target group      <- matches
  │                        20  /*      -> frontend target group
  │                        30  grafana.<domain> -> grafana
  ▼
[3] Target group ─────── contains POD IPs directly (target-type: ip)
  │                      health-checked independently at /healthz
  ▼
[4] app pod (private subnet, port 8080)
  │   otelhttp starts a trace span
  │   middleware records RED metrics and one JSON access log line
  ▼
[5] requireAuth ──────── reads the session cookie
  │                      Redis GET session:<id> → user_id
  ▼
[6] timeline handler
  │   ├─ Redis GET timeline:<user_id>          ← cache hit, ~1ms, done
  │   └─ on miss: Postgres SELECT … JOIN …     ← ~5-20ms
  │                then Redis SET, TTL 30s
  ▼
[7] JSON response back up the same path
```

The page itself took a different branch. `GET /` matched rule 20 and went to
an nginx pod, which returned `index.html` and never touched the API at all.
Two separate images, two Deployments, two target groups, one ALB.

**Rule order is load-bearing.** The frontend's `/*` matches everything,
including `/api`. If its priority were lower than the API's, every API call
would be answered with `index.html` — a total outage that presents as a
frontend bug. That is one of the chaos scenarios (`alb-routing`).

And the asynchronous half, when someone posts:

```
POST /api/posts
  │
  ├─ Postgres INSERT                    (synchronous — must succeed)
  ├─ NATS publish app.post.created      (fire and forget — may fail)
  └─ 201 Created returned to the user
              │
              ▼  (milliseconds later, a different pod)
        worker pod
          ├─ Postgres SELECT follower_ids
          ├─ Redis DEL timeline:<each follower>
          └─ logs fanout_complete, carrying the SAME trace_id
```

That last detail matters: the worker's spans join the trace that the HTTP
request started, because the W3C `traceparent` is carried inside the NATS
message payload. One trace spans two processes.

---

## Layer by layer

### 1. Network (`terraform/vpc.tf`)

```
                Internet
                    │
                 [ IGW ]
                    │
   public-b 10.42.0.0/24 ────── ALB, NAT Gateway
   public-c 10.42.1.0/24 ────── ALB
                    │
              [ NAT GW ]  (single, in AZ-b)
                    │
   private-b 10.42.10.0/24 ──── EKS nodes
   private-c 10.42.11.0/24 ──── EKS nodes
```

The subnet **tags** are load-bearing, not decorative:

| Tag | Read by | If missing |
|---|---|---|
| `kubernetes.io/role/elb=1` on public subnets | AWS LB Controller | Internet-facing ALBs are never created; the Ingress just sits there |
| `kubernetes.io/role/internal-elb=1` on private | AWS LB Controller | Internal load balancers fail the same way |
| `kubernetes.io/cluster/<name>=shared` | Both | Subnet discovery finds nothing |

This is the number one cause of "my Ingress does nothing", and there is no
error message anywhere except the controller's own logs.

### 2. Cluster (`terraform/eks.tf`)

The control plane is AWS-managed; you never see those nodes. What you do see:

- **Managed node group**, 2 × `t4g.large` spot, in the private subnets.
- **Access entries** (`authentication_mode = "API"`), not the legacy
  `aws-auth` ConfigMap. Access is granted by Terraform resources rather than by
  hand-editing a ConfigMap — which was historically an excellent way to lock
  yourself out of a cluster permanently.
- **OIDC provider**, which is the foundation of IRSA. See below.

### 3. IRSA — how a pod gets AWS credentials

This is the single most important AWS-on-Kubernetes concept, and the most
common source of `AccessDenied`.

```
  pod
   │ mounts a projected ServiceAccount JWT at
   │ /var/run/secrets/eks.amazonaws.com/serviceaccount/token
   ▼
  AWS SDK calls sts:AssumeRoleWithWebIdentity with that JWT
   ▼
  STS verifies the signature against the cluster's OIDC provider
   ▼
  STS checks the IAM role's TRUST POLICY:
     does the token's `sub` claim equal
     system:serviceaccount:<namespace>:<serviceaccount>  ?
   ▼
  match → temporary credentials      no match → AccessDenied
```

Three things must agree exactly, or it fails:

1. The **trust policy** in `terraform/irsa.tf` pins a namespace and name.
2. The **ServiceAccount** in `k8s/` lives in that namespace with that name.
3. That ServiceAccount carries the `eks.amazonaws.com/role-arn` annotation.

Rename any one of them and every AWS call from that pod fails. The failure
appears in the *pod's* logs, not in CloudTrail's obvious places.

Two roles use this: the AWS Load Balancer Controller and ExternalDNS. The EBS
CSI driver uses it too, wired automatically by the managed addon.

### 4. Ingress → ALB

The AWS Load Balancer Controller watches `Ingress` objects and reconciles a
real ALB to match. Nothing in `k8s/` creates AWS resources directly — it is all
declarative intent that the controller acts on.

Both Ingresses (app and Grafana) share
`alb.ingress.kubernetes.io/group.name: l2lab`, so **one** ALB serves both
hostnames via host-based routing rules. Without that annotation you would get
two ALBs and two bills.

No certificate ARN is specified anywhere. The controller discovers the matching
ACM certificate by comparing the Ingress `host` rules against the certificates
in the account — our Terraform issues a wildcard that matches.

### 5. ExternalDNS → Route53

Watches Ingress objects, reads the
`external-dns.alpha.kubernetes.io/hostname` annotation, and writes an A-record
alias pointing at the ALB.

Two safety rails matter here, because the hosted zone is **shared with about
thirty other learners**:

- `--domain-filter=sawibowo.sandbox.devopsinstitute.id` — it will not consider
  any record outside our subdomain.
- `--registry=txt` with `--txt-owner-id` — it writes a companion TXT record
  claiming ownership, and refuses to modify records it does not own.

`--policy=sync` allows deletion, which is what makes teardown clean.

### 5b. Secrets

No password exists in this repository. The chain:

```
  Terraform  random_password -> AWS Secrets Manager
        |
  SecretProviderClass   names the secret and the fields to extract (jmesPath)
        |
  ServiceAccount        eks.amazonaws.com/role-arn   (IRSA, per workload)
        |
  Secrets Store CSI     mounts them as files in a tmpfs volume
        |
  container             reads DATABASE_URL_FILE / POSTGRES_PASSWORD_FILE /
                        GF_SECURITY_ADMIN_PASSWORD__FILE
```

The driver and AWS's provider arrive together as one EKS managed addon, so
nothing is vendored.

Files rather than environment variables, for two reasons. **Ordering**: a
Secret synced by the CSI driver only exists once a pod mounting it is running,
but `secretKeyRef` is resolved *before* the container starts, so the first
deploy fails. **Exposure**: environment variables leak into crash dumps,
`kubectl describe`, child processes, and any library that logs its config.

Each workload has its own IRSA role scoped to its own secret, so a compromised
app pod cannot read Grafana's admin password.

### 5c. Frontend and backend as separate images

| | Image | Runs as | Serves |
|---|---|---|---|
| `frontend` | `nginx-unprivileged` + the SPA | uid 101 | `/*` |
| `app` | Go, `FROM scratch` | uid 65534 | `/api/*` |
| `worker` | the `app` image, `/worker` entrypoint | uid 65534 | nothing inbound |

Why split them at all, for an app this small:

- **Blast radius.** A bad frontend push cannot take the API down. They roll and
  roll back independently.
- **Different scaling shapes.** nginx serving static files is nearly free
  (10m CPU, 32Mi); the Go API does bcrypt and database work. Coupling them
  means over-provisioning one to satisfy the other.
- **The routing becomes real.** With one binary there is nothing between the
  ALB and the app to misconfigure. With two, path priority is a genuine
  failure mode you can be taught by.

nginx-unprivileged rather than the standard nginx image: the official one
starts as root and drops privileges in its entrypoint, which the `restricted`
Pod Security Standard forbids. It also runs with a read-only root filesystem —
its config points every scratch directory at an `emptyDir` mounted on `/tmp`.

### 6. Data layer

| | Kind | Why |
|---|---|---|
| **Postgres** | StatefulSet | It owns a disk. A StatefulSet gives a stable name and a stable PVC; a Deployment could start a second pod against the same volume and corrupt it |
| **Redis** | StatefulSet | Same reasoning, for its AOF file |
| **NATS** | Deployment | Core pub/sub, no persistence, no disk — nothing to be stateful about |

Redis holds **sessions** as well as the timeline cache. That is what lets the
API scale to multiple replicas behind the ALB — any pod can serve any user.
It also puts Redis on the critical path for every authenticated request, and
means a Redis flush logs everybody out at once.

`maxmemory 192mb` with `allkeys-lru` is set *below* the 256Mi container limit
so Redis evicts keys itself rather than being OOMKilled. Note that sessions are
evictable too.

### 7. Observability

```
  app pods ──OTLP──────────────────────────► Tempo (traces)
     │
     └─stdout (JSON) ──► Alloy ──► Loki (logs)
                                      ▲
  app /metrics ◄──scrape── Prometheus ─┘
                              ▲
                              └── remote_write ── Tempo metrics-generator
                                                  (span metrics + service graph)
```

- **Prometheus** scrapes anything annotated `prometheus.io/scrape: "true"`,
  plus kube-state-metrics, node-exporter, the kubelet and cAdvisor.
- **Alloy** runs as a DaemonSet, discovers only pods on *its own node*, reads
  their logs through the Kubernetes API, parses the JSON, and ships to Loki.
- **Tempo** receives OTLP directly from the app and stores traces on an EBS
  volume. Its metrics-generator derives a service graph and pushes it back into
  Prometheus.
- **Grafana** has all three wired together with derived fields and exemplars.
- **Alertmanager** receives firing alerts from Prometheus and handles grouping,
  inhibition and silencing. No external receiver is configured — a lab has
  nowhere to page — but the whole lifecycle and UI are there.

#### Labels versus structured metadata

The most important operational fact about Loki: **every distinct combination of
label values creates a stream.** Labels must be low cardinality.

- `namespace`, `pod`, `container`, `app`, `node`, `level` → **labels**.
  A handful of values each.
- `trace_id` → **structured metadata**. Unique per request. As a label it would
  create millions of streams and take Loki down.

This is the mistake that kills self-hosted Loki installations, and it is
configured correctly in `k8s/observability/alloy/configmap.yaml`.

---

## What is deliberately fragile

Not bugs. Understanding them is most of the point.

| Component | Failure mode | Blast radius |
|---|---|---|
| One NAT Gateway (AZ-b) | Losing AZ-b kills egress cluster-wide | No image pulls, no AWS API calls |
| Redis, single replica | Restart drops all sessions | Everyone logged out; timelines fall through to Postgres |
| Postgres, single replica | No failover, no read replica | Total outage for writes and cache misses |
| NATS, no persistence | Restart loses in-flight messages | Timelines stale up to 30s. Degraded, not down |
| Spot nodes, 2 of them | A reclaim removes half the capacity | PDB + topology spread limit the damage |
| Prometheus, 6h retention | Restarting loses history beyond the volume | Post-incident analysis window is short |

---

## Segmentation (applied separately)

`make harden` adds a layer that is deliberately *not* part of the base build:

- **NetworkPolicy**, default-deny with explicit allows. Only enforced because
  the VPC CNI addon sets `enableNetworkPolicy=true` — without that the API
  server accepts every policy and enforces none, which is worse than having
  none at all, because you believe you are segmented.
- **ResourceQuota / LimitRange**, capping how much one namespace can consume so
  a runaway Deployment cannot starve the monitoring you need to diagnose it.
- **Backup CronJob**, `pg_dump` to S3 nightly via IRSA.

It is separate so you get a known-green cluster first. A subtly wrong
NetworkPolicy produces symptoms identical to DNS failure, a dead dependency or
an application bug — you want to be able to say "it broke when I applied
exactly this".

## Reading the system

```sh
make status            # nodes, pods, ingress, anything not Running
make events            # recent cluster events, oldest first
make logs              # tail the app
make grafana           # port-forward, works even when DNS or the ALB is broken
```

The last one matters: if you can only reach Grafana through the ALB, then
whenever the ALB breaks you are blind exactly when you most need to see.
