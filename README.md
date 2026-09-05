# l2lab

A production-shaped AWS environment, built to be broken and diagnosed.
Everything is reproducible from this repo: one command up, one command down,
nothing clicked in a console.

**Region** `ap-southeast-3` (Jakarta) · **Account** `134604498185` (shared learner sandbox)
**Cost** roughly **$0.23/hour**, about **$14 for a weekend**

---

## What gets built

```
                    Route53  sawibowo.sandbox.devopsinstitute.id
                              │   records written by ExternalDNS
                    ┌─────────▼──────────┐
                    │  ALB (one, shared)  │  ACM wildcard cert, HTTP→HTTPS
                    └─────────┬──────────┘
                     managed by AWS Load Balancer Controller (IRSA)
                path routing:  /*  -> frontend   /api/* -> app
     ┌────────────────────────────────────────────────────────┐
     │                 EKS 1.34, private nodes                │
     │                                                        │
     │   ┌──────────┐   ┌─────────┐   ┌────────┐  ┌─────────┐ │
     │   │ frontend │   │   app   │   │ worker │  │ grafana │ │
     │   │  nginx   │   │ Go API  │   └───┬────┘  └─────────┘ │
     │   └──────────┘   └────┬────┘       │                   │
     │                      │   OTLP      │                   │
     │   ┌──────────────────▼─────────────▼─────────────────┐ │
     │   │  Prometheus │ Alertmanager │ Loki │ Tempo        │ │
     │   │             Grafana Alloy (DaemonSet)            │ │
     │   └──────────────────────────────────────────────────┘ │
     │                                                        │
     │   Postgres (StatefulSet) · Redis · NATS                │
     │        ▲ passwords mounted from AWS Secrets Manager    │
     └────────┼───────────────────────────────────────────────┘
         VPC 10.42.0.0/16 · 2 AZ · 1 NAT · 2x t4g.large spot
```

Every backing service runs as a container — that is the point.

| Production would use | Here we run |
|---|---|
| RDS PostgreSQL | `postgres:17-alpine` StatefulSet on EBS |
| ElastiCache | `redis:7.4-alpine` StatefulSet, AOF persistence |
| SQS / MSK | NATS (core pub/sub) |
| CloudWatch / AMP / AMG | Prometheus + Alertmanager + Loki + Tempo + Grafana |

But the things where self-hosting buys nothing are AWS-native, as they should
be in production: **AWS Secrets Manager** for credentials, **ACM** for TLS,
**KMS** for encryption at rest, **ECR** for images, **S3** for backups.

## The application

A small social app: sign up, log in, post, reply, like, follow, browse
profiles. It is small on purpose but *shaped* like production — it touches a
database, a cache and a message bus, and it has a background worker. That shape
is what makes failures propagate realistically.

**Frontend and backend are separate images, separately deployed and scaled.**

| | Image | Serves |
|---|---|---|
| `frontend` | nginx-unprivileged + the SPA | `/*` — HTML, JS, CSS |
| `app` | Go, `FROM scratch` | `/api/*` — JSON only |
| `worker` | same image as `app`, different binary | NATS consumer, no inbound traffic |

One ALB routes between them by path, so the browser calls `/api/...` on the
same origin — no CORS, no proxy hop. The split means a bad frontend push cannot
take the API down, either can be rolled back independently, and the routing
between them becomes a real thing that can be misconfigured (which is one of
the chaos scenarios).

```
POST   /api/signup              bcrypt → Postgres → session in Redis
POST   /api/login               verify → session in Redis
GET    /api/timeline            Redis read-through cache → Postgres on a miss
POST   /api/posts               Postgres write → NATS → worker fans out
GET    /api/posts/{id}          a post plus its replies (thread view)
PUT    /api/posts/{id}/like     idempotent
GET    /api/users               who to follow
GET    /api/users/{name}        profile with counts
GET    /healthz                 liveness  (shallow — checks nothing external)
GET    /readyz                  readiness (deep — checks Postgres and Redis)
GET    /metrics                 Prometheus
```

Every request produces a trace, structured JSON logs carrying that trace's ID,
and RED metrics with exemplars. In Grafana you can go from a latency spike → the
exact trace → the log lines from inside it, in about four clicks.

---

## Quickstart

Prerequisites: `terraform ≥ 1.10`, `kubectl`, `kustomize`, `docker`, `aws` CLI
authenticated to the sandbox account, `jq`. Optionally `ansible`.

```sh
make bootstrap     # once: S3 bucket for terraform state
make up            # everything else (~20 minutes, mostly EKS)
make verify        # prove it actually works
```

Then:

```sh
make seed          # demo users, posts, replies, likes
make load          # continuous traffic, so the dashboards have data
make urls          # public URLs
make password      # the generated Grafana admin password
```

Once it is green and you have looked around, add the segmentation layer:

```sh
make harden        # NetworkPolicy, resource quotas, backup CronJob
```

### Practising RCA

```sh
make chaos         # list the 10 scenarios
make break         # inject a RANDOM fault — you are not told which
make hint          # one nudge
make reveal        # the root cause
make fix           # restore, and record your time to resolution
```

Get a baseline first: run `make load`, open Grafana, and learn what normal
looks like. You cannot recognise an anomaly without it. See `chaos/README.md`.

When you are done:

```sh
make down          # destroy everything
make orphans       # confirm nothing was left behind
```

### Ansible, if you prefer it

Same result, with real idempotency and better failure output:

```sh
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml
ansible-playbook verify.yml
```

See `ansible/README.md` for the day-2 playbooks — diagnostics collection,
backup/restore, secret rotation, scaling and ordered teardown.

---

## Layout

```
terraform/        AWS only — VPC, EKS, IRSA, addons, ACM, KMS,
                  Secrets Manager, ECR, S3 backups
app/              Go: API + worker. One image, two binaries. JSON only.
frontend/         nginx + the single-page app. Separate image.
k8s/
  base/           namespaces, gp3 StorageClass
  platform/       AWS Load Balancer Controller, ExternalDNS
  data/           Postgres, Redis, NATS, SecretProviderClasses
  observability/  Prometheus, Alertmanager, Loki, Tempo, Grafana, Alloy
  app/            Deployments, Service, Ingress, HPA, PDB
  hardening/      NetworkPolicy, quotas, backup CronJob  (applied separately)
ansible/          orchestration, verification, day-2 operations
chaos/            10 RCA practice scenarios, injectable and reversible
scripts/          seed and load generation
docs/             architecture, decisions, runbook, RCA template
```

Terraform manages AWS. `kubectl apply -k` manages Kubernetes. They are kept
separate on purpose: Terraform's Kubernetes provider has to configure itself
against a cluster that does not exist during the first plan, which is a
well-known source of pain and makes `destroy` unreliable.

**There is no Helm anywhere.** Commodity components come from EKS managed
addons; everything else is plain YAML you can read.

**There are no passwords in this repository.** Terraform generates them into
AWS Secrets Manager; the Secrets Store CSI driver mounts them into only the
pods entitled to see them.

---

## Where to look when something breaks

```sh
make status        # nodes, pods, ingress, anything not Running
make events        # recent cluster events
make logs          # tail the application
make grafana       # port-forward Grafana — works even if DNS or the ALB is broken
make diagnose      # full evidence snapshot for an RCA
```

`docs/RUNBOOK.md` has the first-response procedure and the specific failure
modes this stack is prone to.

---

## Documentation

| Document | What it covers |
|---|---|
| `docs/ARCHITECTURE.md` | How a request flows end to end, and why each piece exists |
| `docs/DECISIONS.md` | Every design decision, the alternatives, and what each costs |
| `docs/RUNBOOK.md` | Verification steps and first-response troubleshooting |
| `docs/rca/TEMPLATE.md` | RCA template, ITIL-shaped |
| `ansible/README.md` | What Ansible is and is not doing here, and why |
| `chaos/README.md` | The RCA practice scenarios and how to use them properly |
| `k8s/platform/aws-lbc/README.md` | Why the load balancer controller is installed the way it is |

---

## Cost breakdown

| Item | $/hour | Note |
|---|---|---|
| EKS control plane | 0.100 | Unavoidable. Must stay on a **standard-support** version — 1.33 and older are extended support at **$0.60/hr** |
| 2 × t4g.large spot | 0.054 | Graviton, ~70% off on-demand. AZ-a excluded, it is 46% pricier |
| NAT Gateway | 0.045 | One, not one per AZ |
| ALB | 0.023 | One, shared by the app and Grafana via `group.name` |
| EBS gp3 (~37 GiB) | 0.005 | Postgres, Redis, Prometheus, Loki, Tempo, Grafana, Alertmanager |
| KMS + Secrets Manager | 0.002 | One key, two secrets |
| **Total** | **~0.229** | **~$14 for 58 hours** |

`make cost` shows account-wide month-to-date spend. Remember this budget is
shared with about thirty other learners.

**`make sleep`** scales the node group to zero (~$0.23/hr → ~$0.16/hr) for a
break. It does not stop the control plane, which cannot be paused — if you are
finished for the day, `make down` is the honest answer.
