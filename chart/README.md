# l2lab Helm chart

The whole stack as one chart: data layer, observability, application, ingress
and optional hardening. Built so ArgoCD can be the source of truth.

## Why this replaced the Kustomize tree

The old `k8s/` layout could not be driven by GitOps, for two concrete reasons:

1. **`k8s/platform/aws-lbc/upstream.yaml` was gitignored.** It was fetched at
   deploy time by `make vendor`. ArgoCD syncs *from git*, so it would have
   found an empty directory and never installed the load balancer controller —
   no ALB, nothing reachable. That file is gone; the controller is now a chart
   dependency on AWS's own published chart.

2. **Two values were baked into YAML but only knowable after `terraform apply`** —
   the VPC id and the image tags. `make deploy` stamped them in locally, which
   meant the cluster and git were never the same thing. They are values now.

## Required values

| Value | Where it comes from |
|---|---|
| `global.vpcId` | `terraform -chdir=terraform output -raw vpc_id` |
| `aws-load-balancer-controller.vpcId` | same value — a subchart cannot read the parent's values |
| `app.image.tag` | the git SHA you pushed to ECR |
| `frontend.image.tag` | same |

The chart **refuses to render** without these, with a message telling you
where to get them. That is deliberate: an empty `vpcId` used to install
"successfully" and then the controller would log

```
couldn't auto-discover subnets: unable to resolve at least one subnet.
Evaluated 0 subnets: 0 are tagged for other clusters, ...
```

which reads like a subnet-tagging problem and sends you into `terraform/vpc.tf`
looking for a bug that isn't there. (*"Evaluated 0"* is the tell — wrong tags
would evaluate the subnets and reject them; evaluating none means it is
searching the wrong VPC.)

## Install directly with Helm

**Must be `-n kube-system`.** Only the load balancer controller subchart
follows the release namespace; everything else pins its own. Installing into
`default` scatters the controller where nobody looks, so the chart refuses.

```sh
VPC=$(terraform -chdir=terraform output -raw vpc_id)
TAG=$(git rev-parse --short HEAD)

helm dependency update ./chart

helm upgrade --install l2lab ./chart \
  -n kube-system --create-namespace \
  --set global.vpcId=$VPC \
  --set aws-load-balancer-controller.vpcId=$VPC \
  --set app.image.tag=$TAG \
  --set frontend.image.tag=$TAG
```

Then, once it is green:

```sh
helm upgrade l2lab ./chart -n kube-system --reuse-values \
  --set hardening.enabled=true
```

## Sync waves

Ordering matters, and ArgoCD applies everything at once unless told otherwise.
Every object carries `argocd.argoproj.io/sync-wave`:

| Wave | What | Why here |
|---|---|---|
| `-2` | Namespaces, StorageClass | everything else lives in them |
| `-1` | ServiceAccounts, SecretProviderClasses | pods mount these at start |
| `0` | ExternalDNS, load balancer controller | must exist before Ingresses |
| `1` | Postgres, Redis, NATS | the app's dependencies |
| `2` | monitoring-role Job (also a Helm hook) | needs Postgres up |
| `3` | app, frontend, worker, observability | needs the data layer |
| `4` | Ingresses | needs Services and the controller |

These annotations are inert under plain `helm install` — Helm orders by kind —
so they cost nothing if you are not using ArgoCD.

## Things the templates encode that are easy to get wrong

Each of these was a real incident during this project:

- **No `replicas` when an HPA exists.** Setting it makes the manifest and the
  autoscaler fight: every sync resets it, the HPA scales it back.
- **`maxUnavailable`, never `minAvailable`, in the PDBs.** With a floor of one
  replica, `minAvailable: 1` makes the only pod un-evictable and deadlocks
  `kubectl drain` forever.
- **No readiness probe on the metrics sidecars.** Container readiness rolls up
  into pod readiness, and the Postgres Service is headless, so an unready
  exporter makes the *database* unresolvable cluster-wide.
- **`{{ }}` escaped with backticks** in the Prometheus rules, Alertmanager
  templates, Grafana dashboards and the StorageClass tags. Four different
  systems use that syntax and none of them are Helm.
- **JMESPath keys quoted** in the Grafana SecretProviderClass. Unquoted,
  `admin-user` parses as `admin` *minus* `user`, and the provider reports a
  useless "failed to fetch secret from all regions".
- **Ingress `group.order`:** `/api` at 10 must beat the frontend's `/*` at 20,
  or every API call is answered with `index.html`.

## Values worth knowing

```yaml
hardening.enabled: false     # NetworkPolicy, quotas, backups. Turn on last.
observability.enabled: true  # the whole LGTM stack
worker.workDelay: ""         # set to "15s" to simulate a lagging consumer
app.autoscaling.maxReplicas  # keep quota >= usage + (max-min) x request
```

`helm show values ./chart` for the full set — every entry is commented.

## What is NOT in this chart

- **AWS infrastructure** — still Terraform. VPC, EKS, IAM, KMS, Secrets
  Manager, ECR, ACM. Terraform has a state file and a dependency graph; Helm
  has neither.
- **Secrets** — no passwords anywhere in this repo. Terraform generates them
  into AWS Secrets Manager; the Secrets Store CSI driver mounts them as files
  into only the pods entitled to read them.
- **ArgoCD itself** — install and configure it yourself. The chart is written
  to be driven by it, not to install it.
