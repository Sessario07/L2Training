# Design decisions

Every non-obvious choice, what it was chosen over, and what it costs. Written
so that when something breaks you can tell "this is deliberate" from "this is
a bug", and so you can argue with the reasoning rather than guess at it.

---

## Cost and lifetime

### Region ap-southeast-3, two AZs, not three

The shared sandbox account is in Jakarta. Two AZs is the minimum an ALB will
accept, and each additional AZ adds nodes and cross-AZ data transfer for no
learning benefit in a lab that will not survive an AZ failure test anyway.

### AZ-a is deliberately excluded

Spot pricing for `t4g.large` when this was built:

| AZ | $/hr |
|---|---|
| ap-southeast-3a | 0.0385 |
| ap-southeast-3b | 0.0274 |
| ap-southeast-3c | 0.0263 |

AZ-a is ~46% more expensive for an identical instance. Using b and c is free
money. **Spot prices move**, so re-check before a long-lived rebuild:

```sh
aws ec2 describe-spot-price-history --region ap-southeast-3 \
  --instance-types t4g.large --product-descriptions "Linux/UNIX" \
  --start-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
  --query 'SpotPriceHistory[].[AvailabilityZone,SpotPrice]' --output text
```

### EKS 1.34, not 1.33

1.33 and below are in **extended support**, which costs **$0.60/hr** for the
control plane instead of $0.10/hr. Six times the price on the single largest
line item. Always check before pinning a version:

```sh
aws eks describe-cluster-versions --region ap-southeast-3 \
  --query 'clusterVersions[].[clusterVersion,status]' --output text
```

### Graviton (arm64) spot instances

Cheaper than the x86 equivalent, and the build machine is an Apple Silicon Mac,
so container images build natively with no QEMU emulation. Every image in this
stack publishes a multi-arch manifest, so nothing had to be compromised.

Spot rather than on-demand saves roughly 70%. The tradeoff is that AWS can
reclaim a node with two minutes' notice. With two nodes that means losing half
the capacity — which is why the app uses `topologySpreadConstraints` and a PDB.

### 2 × t4g.large, not 3

Total memory requests across the whole stack are about **2.4 GiB**. Two
`t4g.large` nodes provide roughly **13.5 GiB** allocatable. Three would have
been five times more headroom than the workload can use.

`t4g.medium` (4 GiB) would also fit and would save **$1.81** across the whole
weekend. Not worth it: the extra headroom means nothing gets mysteriously
evicted while you are still learning to tell a real failure from a sizing
mistake.

### One NAT Gateway, not one per AZ

$0.045/hr instead of $0.090/hr. The consequence is real and worth understanding:
all egress from AZ-c nodes crosses into AZ-b, and losing AZ-b removes internet
access for the entire cluster. That is a genuine single point of failure, left
in deliberately.

An S3 Gateway endpoint is attached to the private route table. It is free and
keeps ECR image-layer downloads (which are served from S3) off the NAT Gateway,
avoiding per-GB data processing charges on every image pull.

---

## Tooling

### Terraform for AWS, kubectl+Kustomize for Kubernetes

They are *not* mixed. Terraform's Kubernetes and Helm providers have to
configure themselves against a cluster that does not exist during the first
plan, which produces the classic "provider configuration is not known until
apply" failure and makes `destroy` unreliable.

Splitting them means each tool does what it is good at, and the Makefile
sequences them.

### No Helm at all

Requested, and it turned out to be practical. Commodity components come from
EKS managed addons; the rest is hand-written YAML.

The one gap is the AWS Load Balancer Controller, which has no managed-addon
equivalent. Its upstream pre-rendered manifest bundle is vendored into
`k8s/platform/aws-lbc/upstream.yaml` and patched with Kustomize.

The real benefit is not ideological: **`kubectl get -o yaml` matches what is in
the repo.** With Helm, what you read in a values file and what actually runs
are separated by a layer of Go templating, which is an obstacle when you are
trying to learn what a manifest does.

### Raw Terraform resources, not community modules

`terraform-aws-modules/eks` is roughly 8,000 lines of indirection. It is the
right choice for a team that already knows EKS and wants defaults. It is the
wrong choice when the point of the exercise is to see what an EKS cluster is
actually made of.

### EKS managed addons wherever possible

`vpc-cni`, `kube-proxy`, `coredns`, `aws-ebs-csi-driver`, `metrics-server`,
`kube-state-metrics`, `prometheus-node-exporter`, `cert-manager`. AWS installs
and upgrades these; they contribute zero YAML to this repo.

ExternalDNS is *not* used as a managed addon even though one exists, because
its addon does not publish a pod-identity configuration in this region, so the
ServiceAccount name would have been a guess. Hand-writing it is ~100 lines and
removes the uncertainty.

### VPC CNI prefix delegation is enabled

Without it, a `t4g.large` is capped at 35 pods because each pod consumes a
secondary ENI IP address. With it, nodes allocate `/28` prefixes and the cap
rises to 110. It is a single environment variable and it eliminates the
"pod stuck in ContainerCreating, no IP addresses available" failure class.

---

## Simplifications, and what they cost

These were cut to keep the component count manageable. Each is a legitimate
production choice being traded away, so it is worth knowing what was given up.

| Cut | Instead | What is lost |
|---|---|---|
| MinIO | Loki/Tempo write to an EBS volume | No S3-compatible object store to learn; storage is AZ-bound and does not scale |
| CloudNativePG operator | Plain Postgres StatefulSet | No automated failover, no PITR, no read replicas. ~40 readable lines instead of a CRD and a reconciliation loop |
| Prometheus Operator | Plain Prometheus + a ConfigMap | No `ServiceMonitor` CRDs — but the scrape config is *visible*, which teaches how Kubernetes service discovery actually works |
| NATS JetStream | Core NATS pub/sub | Messages are not durable; a NATS restart loses in-flight events. Timelines go stale for up to 30s rather than being wrong forever |
| Alertmanager receivers | Alertmanager with a null receiver | Alerts group, inhibit and can be silenced — you get the whole lifecycle and UI — but nothing is sent anywhere, because a lab has nowhere to page |
| ArgoCD | `kubectl apply -k` plus Ansible | No GitOps, no drift detection, no sync-failure surface |

---

## Secrets

### AWS Secrets Manager, not Kubernetes Secrets

There are no passwords in this repository. Terraform generates them with
`random_password`, writes them to Secrets Manager, and the **Secrets Store CSI
driver** mounts them into the pods entitled to see them.

The driver and AWS's provider plugin arrive as a *single* EKS managed addon
(`aws-secrets-store-csi-driver-provider`) — its configuration schema has a
nested `secrets-store-csi-driver` block, so the base driver installs with it.
Nothing has to be vendored from upstream.

**Secrets are read from mounted FILES, not environment variables.** Postgres and
Grafana support that natively (`POSTGRES_PASSWORD_FILE`,
`GF_SECURITY_ADMIN_PASSWORD__FILE`); the Go app gained the same convention in
`internal/obs/env.go`. Two reasons:

1. **Ordering.** A Secret synced by the CSI driver only exists once a pod
   mounting the SecretProviderClass is running — but `secretKeyRef` is resolved
   *before* the container starts. The first deploy fails with
   `CreateContainerConfigError` and it is not obvious why.
2. **Exposure.** Environment variables leak into crash dumps, `kubectl describe`
   of a pod spec, child processes, and any library that logs its configuration.
   A file read once at startup does not.

Each workload gets its **own IRSA role scoped to its own secret**. A compromised
application pod cannot read Grafana's admin password, and vice versa.

The honest caveat: generated values still land in **Terraform state**, which is
why the state bucket is encrypted and access-controlled. That is inherent to
Terraform. The production alternative is to let Secrets Manager generate and
rotate the value with a Lambda and have Terraform reference only the ARN.

### Envelope encryption for etcd

By default EKS stores Secret objects base64-encoded but **not encrypted**. A
customer-managed KMS key (`kms.tf`) enables envelope encryption, so an etcd
snapshot is useless on its own. Note this is one-way: AWS lets you turn
encryption on for an existing cluster, never off.

---

## Ansible

Deliberately *not* used for Kubernetes manifests or AWS resources. Kustomize and
Terraform are better at those, and replacing them would mean losing
`kubectl diff`, strategic merge patches, plan/apply and reliable teardown.

It is used for the three things it is genuinely better at than a Makefile:

- **Orchestration** — `terraform plan -detailed-exitcode` makes a no-op run
  report *no change* instead of re-applying; an image already in ECR is not
  rebuilt; flaky steps retry.
- **Verification** — `verify.yml` turns the runbook's manual checks into
  assertions. Pass/fail beats "that output looks about right".
- **Day-2 operations** — multi-step procedures with ordering constraints and
  guard rails. `ops/teardown.yml` encodes the ordering that makes a destroy
  work; `ops/diagnostics.yml` captures evidence before it rotates away.

That last category is the *"write and refine automation scripts to resolve or
prevent recurring issues"* line of an L2 job description, made concrete.

---

## Security posture

This is a **lab**, so a few things are deliberately weakened. They are listed so
nothing is mistaken for a recommendation.

**Done properly:**
- Nodes in private subnets, reachable only through the ALB
- No credentials in the repository — Secrets Manager + CSI driver, per-workload
  IRSA roles scoped to individual secrets
- Kubernetes Secrets encrypted at rest in etcd with a customer-managed KMS key
- IRSA trust policies scoped to a single named ServiceAccount
- ExternalDNS restricted by both `--domain-filter` and a TXT ownership registry,
  so it cannot touch the other thirty learners' DNS records
- `restricted` Pod Security Standard on the `l2lab` namespace
- Containers run as non-root, read-only root filesystem, all capabilities dropped
- Application image built `FROM scratch` — no shell, no package manager
- ECR: immutable tags, scan on push, encrypted
- EBS volumes encrypted; S3 buckets encrypted with public access blocked
- NetworkPolicy default-deny, with explicit allows (via `make harden`)
- Resource quotas and LimitRanges capping blast radius
- Grafana: anonymous access off, sign-up disabled, secure cookies
- Nightly encrypted database backups to S3, with a tested restore path

**Deliberately weakened, and why:**
- The EKS API endpoint is publicly reachable so `kubectl` works without a
  bastion. It still requires IAM auth. Narrow `api_public_access_cidrs` to close
  it — the variable exists for that.
- Postgres connections use `sslmode=disable`. Acceptable only because the
  traffic never leaves private subnets.
- Kubernetes audit logging is off by default (`enable_audit_logs`). Production:
  always on. Here it is $0.50–1.00/day of CloudWatch ingestion for data you will
  probably never read.
- VPC Flow Logs off by default (`enable_flow_logs`), same reasoning.
- `force_destroy = true` on the S3 buckets and `recovery_window_in_days = 0` on
  the secrets, so a lab can be rebuilt repeatedly. Both would be dangerous in
  production — the second means a deleted secret is gone immediately.

## Observability

### Prometheus + Loki + Tempo, not CloudWatch

Requested (self-hosted everything), and it is the better teaching choice
regardless: it is the stack most companies actually run, and correlation
between the three signals is configurable in a way CloudWatch's is not.

Retention is short on purpose — Prometheus 6h, Loki 24h, Tempo 24h. This
environment lives for a weekend; longer retention only buys disk cost.

### Correlation is the whole point

Three separate databases are easy. What makes them useful is the links:

- The app writes `trace_id` into every JSON log line.
- Alloy puts `trace_id` into Loki **structured metadata**, not a label.
  As a label it would create a stream per request and destroy Loki — label
  cardinality is the number one way people break it.
- Grafana's Loki datasource declares a derived field on `trace_id`, so every
  log line gets a "View trace" button.
- Prometheus histograms carry **exemplars**: a trace ID attached to a bucket.
  Clicking a dot on the latency graph opens that request's trace.
- Tempo's datasource declares `tracesToLogsV2`, so a span links back to the
  logs written inside it.

The loop closes: **metric → trace → log → metric.**

### Tempo's metrics-generator writes back into Prometheus

`service-graphs` and `span-metrics` processors derive RED metrics and a service
topology from the traces themselves, then remote-write them to Prometheus.
That is what draws the automatic service map in Grafana with no extra
instrumentation. It requires `--web.enable-remote-write-receiver` on Prometheus.

### Grafana Alloy, not Promtail

Promtail reached end of life in 2025. Alloy is its successor. It reads pod logs
through the Kubernetes API rather than mounting `/var/log` from the host, so the
DaemonSet needs no privileged access and no hostPath volumes.

---

## Application design

### Go

Chosen because the app is primarily a realistic workload to *observe*, not code
to hand-edit. A ~20 MB static image, native arm64 builds, and the best
OpenTelemetry support available. The tradeoff: `FROM scratch` means no shell, so
`kubectl exec` into the app container will not work — debugging happens through
telemetry, which is the intended lesson.

### Liveness and readiness are deliberately different

The most commonly botched thing in real clusters.

- **`/healthz` (liveness)** checks nothing external. If it checked Postgres, a
  database blip would restart every API pod and turn a recoverable dependency
  outage into a cluster-wide crash loop.
- **`/readyz` (readiness)** checks Postgres and Redis. Failing removes the pod
  from the ALB target group *without* restarting it, so it recovers on its own.
- NATS is checked but **does not gate readiness**. The app works without it;
  only background fan-out stops. Failing readiness there would take the site
  down over a degraded background job.

### Memory limits, no CPU limits

Memory is incompressible: exceed it and the kernel OOMKills the container.
It must be bounded.

CPU is compressible: a limit only causes CFS throttling, which shows up as
mysterious latency. Requests provide scheduling guarantees without the
throttling. `container_cpu_cfs_throttled_seconds_total` is on the dashboard so
you can *see* throttling when it happens elsewhere.

### The connection pool is small on purpose

`MaxConns = 10` per pod. Postgres defaults to `max_connections = 100` shared
across every client. Two API pods plus a worker at 10 each is 30 — comfortable.
Set it to 100 per pod and the third pod cannot connect at all. Pool exhaustion
presents as "the database is slow" when the database is in fact idle, which is
why `app_db_pool_acquired_connections` is on the dashboard.

### Fan-out is asynchronous and failure-tolerant

Posting writes to Postgres, then publishes to NATS. If the publish fails, the
request still succeeds — the post is durably stored, and stale timelines expire
within 30 seconds anyway.

This creates the most useful failure mode in the whole stack: the site is *up*
but *stale*. Distinguishing degraded from broken is the core L2 triage skill,
and you cannot practise it without an asynchronous component.

---

## Known gap in the currently-running environment

The `aws_launch_template.node` resource exists and the node group references
it in code, but the **live** node group was created before that reference was
added, so the running instances use EKS's own auto-generated launch template.

Consequence: the launch template's `tag_specifications` (and its IMDSv2
setting) are not in effect on the current nodes. They were tagged manually with
`aws ec2 create-tags` to close the cost-attribution gap, but an ASG replacement
of an instance would lose those tags.

The instances remain unambiguously identifiable regardless, via the tags EKS
sets itself:

```
eks:cluster-name              = l2lab-sawibowo
eks:nodegroup-name            = l2lab-sawibowo-ng
kubernetes.io/cluster/l2lab-sawibowo = owned
```

A `make down` + `make up` resolves it permanently. An in-place `terraform
apply` also fixes it but forces a node group replacement — both nodes are
destroyed and recreated, and every pod reschedules.

---

## Things that will bite you

Collected here because each one has a non-obvious symptom.

| Symptom | Cause |
|---|---|
| Ingress created, no ALB ever appears | Public subnets missing `kubernetes.io/role/elb=1`; or the controller's IRSA annotation does not match its trust policy. Check the controller logs first |
| Every AWS call returns `AccessDenied` | IRSA trust policy `sub` claim does not exactly match `system:serviceaccount:<ns>:<sa>` |
| Pod stuck `Pending` with a volume node affinity conflict | EBS is AZ-locked. The StorageClass uses `WaitForFirstConsumer` to prevent this; `Immediate` binding would cause it |
| Postgres crash-loops on first boot | `PGDATA` must be a *subdirectory* of the mount — an EBS volume arrives with `lost+found`, and `initdb` refuses a non-empty directory |
| 502s during every deploy | Target-group deregistration is not instant. The app sleeps `PRESTOP_DELAY` before draining; `terminationGracePeriodSeconds` must exceed that plus the drain budget |
| `kubectl drain` hangs forever | A PDB with `minAvailable` equal to the replica count. Self-inflicted deadlock |
| Loki falls over | Someone put a high-cardinality value in a *label* instead of structured metadata |
| Users randomly logged out | Redis hit `maxmemory` and evicted session keys under `allkeys-lru` |
| Terraform `destroy` fails on the VPC | An ALB the controller created still holds an ENI. Delete the Kubernetes Ingress objects first — `make down` does this in order |
