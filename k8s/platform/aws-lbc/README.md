# AWS Load Balancer Controller

`upstream.yaml` is **not** committed by the build. Fetch it before the first
apply:

```sh
curl -sSfL -o upstream.yaml \
  https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases/download/v2.13.4/v2_13_4_full.yaml
```

## Why this component is installed from raw manifests

Everything else in this cluster is either an EKS managed addon or hand-written
YAML. This is the one piece with no managed-addon equivalent, and upstream
publishes it as a Helm chart plus a pre-rendered manifest bundle. We use the
pre-rendered bundle so the whole repo stays Helm-free.

## Why cert-manager is required

The bundle declares a validating/mutating admission webhook whose TLS
certificate is issued by cert-manager. That is why `terraform/addons.tf`
installs the `cert-manager` EKS managed addon. If cert-manager is missing, the
controller's pods start but every Ingress write is rejected by a webhook whose
certificate never appears.

## What the two patches do

| Patch | Why |
|---|---|
| `patch-serviceaccount.yaml` | Adds the IRSA role ARN. Without it: `AccessDenied` on every AWS call, and no ALB is ever created. |
| `patch-deployment.yaml` | Supplies `--cluster-name`, without which the controller cannot find the tagged subnets. |

## First place to look when an ALB does not appear

```sh
kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=100
kubectl describe ingress -n l2lab app
```

The three usual causes, in order of frequency:

1. Public subnets missing the `kubernetes.io/role/elb=1` tag.
2. The IRSA annotation or the role's trust policy not matching
   `system:serviceaccount:kube-system:aws-load-balancer-controller`.
3. No ACM certificate whose domains match the Ingress `host` rule.
