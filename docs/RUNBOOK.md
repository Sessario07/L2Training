# Runbook

Two parts: **verification** (prove the build actually worked) and
**first response** (what to do when it does not).

Most of Part 1 is automated:

```sh
make verify        # or: cd ansible && ansible-playbook verify.yml
```

Read it anyway. The point of doing it by hand once is that you learn what each
check proves, so that when one fails you know what it was telling you.

---

# Part 1 — Verification

Run these in order after `make up`. Each one has an expected result; if you get
something else, stop there rather than continuing, because everything after it
depends on it.

## 1. Infrastructure exists

```sh
terraform -chdir=terraform output
```

Expect: `cluster_name`, `app_url`, `grafana_url`, `ecr_repository_url`, and an
`acm_certificate_arn`. A missing certificate ARN means DNS validation never
completed.

```sh
aws eks describe-cluster --region ap-southeast-3 --name l2lab-sawibowo \
  --query 'cluster.{status:status,version:version,endpoint:endpoint}'
```

Expect `"status": "ACTIVE"` and `"version": "1.34"`.

## 2. Nodes are ready

```sh
kubectl get nodes -o wide
```

Expect **2 nodes**, both `Ready`, in `ap-southeast-3b` and `-3c`, running
`AL2023` on `arm64`. If a node is missing, spot capacity may have been
unavailable — check:

```sh
aws eks describe-nodegroup --region ap-southeast-3 \
  --cluster-name l2lab-sawibowo --nodegroup-name l2lab-sawibowo-ng \
  --query 'nodegroup.{status:status,health:health}'
```

## 3. Addons are healthy

```sh
aws eks list-addons --region ap-southeast-3 --cluster-name l2lab-sawibowo
kubectl get pods -n kube-system
```

Expect `coredns`, `aws-node`, `kube-proxy`, `ebs-csi-*`, `metrics-server`,
`kube-state-metrics`, `prometheus-node-exporter`, `cert-manager`,
`aws-load-balancer-controller`, `external-dns` — all `Running`.

## 4. IRSA actually works

This is worth checking explicitly, because a broken IRSA setup produces silence
rather than an error.

```sh
kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=30
kubectl logs -n kube-system deploy/external-dns --tail=30
```

Expect no `AccessDenied` and no `WebIdentityErr`. ExternalDNS should log that
it found the hosted zone. Confirm the annotation is actually present:

```sh
kubectl get sa -n kube-system external-dns aws-load-balancer-controller \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}{end}'
```

## 5. Storage provisions

```sh
kubectl get pvc -A
```

Expect every PVC `Bound`. Anything stuck `Pending` for more than a minute means
the EBS CSI driver cannot create volumes — almost always its IRSA role.

## 5b. Secrets arrive from Secrets Manager

Nothing in this repo contains a password, so a broken secret chain shows up as
pods that will not start. Confirm the mount works:

```sh
kubectl exec -n l2lab postgres-0 -- sh -c 'test -s /mnt/secrets/postgres-password && echo MOUNTED'
kubectl exec -n l2lab deploy/app  -- sh -c 'ls -l /mnt/secrets/' 2>/dev/null || \
  kubectl describe pod -n l2lab -l app=app | grep -A5 'secrets'
```

Expect `MOUNTED`. If the pod is stuck, the CSI driver reports why in the pod's
events:

```sh
kubectl describe pod -n l2lab postgres-0 | tail -25
kubectl logs -n kube-system -l app=secrets-store-csi-driver --tail=50
```

Walk the chain in `k8s/data/secrets/secretproviderclass.yaml` in order. It is
nearly always the IRSA trust policy, or a ServiceAccount name that does not
match what the trust policy pins.

Confirm the values are actually the generated ones, not defaults:

```sh
make password        # prints the generated Grafana password
```

## 6. Data layer

```sh
kubectl exec -n l2lab postgres-0 -- pg_isready -U l2lab -d l2lab
kubectl exec -n l2lab redis-0 -- redis-cli ping
kubectl exec -n l2lab deploy/nats -- wget -qO- localhost:8222/healthz
```

Expect `accepting connections`, `PONG`, and `{"status":"ok"}`.

Confirm the migrations ran:

```sh
make psql
\dt
```

Expect `users`, `posts`, `follows`.

## 7. The application

```sh
kubectl get pods -n l2lab
kubectl logs -n l2lab -l app=app --tail=20
```

Expect 2 `app` pods and 1 `worker`, all `1/1 Running`, and a log line
`"message":"api listening"`. The logs must be **JSON** — if they are plain
text, the logger is misconfigured and Loki parsing will fail downstream.

```sh
kubectl run -n l2lab curl --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s http://app.l2lab.svc.cluster.local/readyz
```

Expect `{"ready":true,"checks":{"nats":"ok","postgres":"ok","redis":"ok"}}`.

## 8. ALB and DNS

```sh
kubectl get ingress -A
```

Expect **both** Ingresses to show the *same* ADDRESS — that is the shared ALB
working. An empty ADDRESS means the controller has not reconciled; check its
logs.

```sh
dig +short app.sawibowo.sandbox.devopsinstitute.id
curl -sI https://app.sawibowo.sandbox.devopsinstitute.id | head -1
```

Expect an IP, then `HTTP/2 200`. Allow 1–2 minutes for propagation after the
ALB first appears.

Confirm the target group is healthy — Kubernetes-Ready and ALB-healthy are
*different things*:

```sh
aws elbv2 describe-target-groups --region ap-southeast-3 \
  --query 'TargetGroups[?contains(TargetGroupName,`l2lab`)].TargetGroupArn' --output text \
  | tr '\t' '\n' | while read -r tg; do
      aws elbv2 describe-target-health --region ap-southeast-3 --target-group-arn "$tg" \
        --query 'TargetHealthDescriptions[].{t:Target.Id,h:TargetHealth.State}' --output text
    done
```

## 9. End to end

```sh
make seed
make load     # leave running in another terminal
```

Open the app URL, log in as `alice` / `password123`, post something, refresh
twice. The "served from" line should flip from `database` to `cache`.

## 10. Observability — the part that actually matters

```sh
make grafana    # http://localhost:3000, admin / l2lab-admin
```

Then, in order:

1. **Dashboards → l2lab → Application Overview.** Request rate, error ratio and
   p99 should all be populated. If they are flat zero, Prometheus is not
   scraping — check `Status → Targets` at `make prometheus`.

2. **Explore → Loki**, query `{namespace="l2lab"}`. Expect JSON log lines.
   Expand one: it should have a `trace_id` in structured metadata and a
   **"View trace"** button.

3. **Click that button.** Tempo should open the trace, showing spans nested:
   `http` → `redis.get_session` → `redis.get_timeline` → `postgres.timeline`.
   *This is the payoff. If this works, the whole observability stack is wired
   correctly.*

4. **Post something, then find the trace for the POST.** It should contain a
   `nats.publish` span, and — because the traceparent is carried in the message
   — the worker's `nats.receive` span in the same trace.

5. **Explore → Tempo → Service Graph.** Expect an automatically drawn topology
   of `l2lab-api` → `l2lab-worker`. This comes from Tempo's metrics-generator
   writing into Prometheus; if it is empty, remote-write is not working.

6. On the **Latency percentiles** panel, hover a dot on the line — that is an
   exemplar. Clicking it opens that exact request's trace.

If all six work, you have a genuinely correlated observability stack, which is
more than a lot of production environments have.

7. **Alertmanager.** `kubectl -n observability port-forward svc/alertmanager 9093`
   then open <http://localhost:9093>. Alerts that Prometheus has fired appear
   here grouped. Try silencing one and watch it disappear — the silence
   survives a restart because Alertmanager has a PVC.

## 11. Hardening (after the base stack is green)

```sh
make harden
make status && make verify
```

`make harden` applies NetworkPolicy, resource quotas and the backup CronJob.
Applying it separately is deliberate: if something breaks immediately
afterwards, you know exactly which change caused it. `make unharden` reverses
it, which is how you confirm the hypothesis.

Then prove backups actually work — an untested backup is an assumption:

```sh
cd ansible && ansible-playbook ops/backup-db.yml
aws s3 ls s3://l2lab-sawibowo-backups-134604498185/postgres/ --human-readable
```

And, at least once while nothing is on fire, prove the *restore* works:

```sh
ansible-playbook ops/restore-db.yml -e confirm=yes
```

---

# Part 2 — First response

## The general procedure

Resist the urge to start fixing. Work outside in — the failure is at one hop,
and guessing which one wastes more time than checking.

0. **Capture the evidence first.** `make diagnose` takes about twenty seconds
   and snapshots events, pod state, resource usage, ALB target health and
   — crucially — `kubectl logs --previous` for anything that has restarted.
   Evidence rotates away while you are still forming a hypothesis: pods
   restart, logs roll, events expire after an hour.
1. **What is the symptom, precisely?** "The site is down" is not a symptom.
   "HTTPS requests to /api/timeline return 502" is.
2. **What changed?** `kubectl get events -A --sort-by=.lastTimestamp | tail -40`
3. **Which hop?** Walk the path in `ARCHITECTURE.md` from the outside in:
   DNS → ALB → target group → pod → dependency.
4. **Only then form a hypothesis**, and check it with one command.

## Narrowing down which hop

```sh
# DNS resolving?
dig +short app.sawibowo.sandbox.devopsinstitute.id

# ALB answering at all?
curl -sI https://app.sawibowo.sandbox.devopsinstitute.id | head -1

# Bypass the ALB entirely — is the pod itself fine?
kubectl port-forward -n l2lab deploy/app 8080:8080
curl -s localhost:8080/readyz | jq

# Bypass the app — are the dependencies fine?
kubectl exec -n l2lab postgres-0 -- pg_isready -U l2lab -d l2lab
kubectl exec -n l2lab redis-0 -- redis-cli ping
```

Whichever is the first to fail tells you where to look. If `port-forward` works
but the ALB does not, the problem is in ALB/target-group/DNS — not the app.

## Symptom → likely cause

### No ALB is created

```sh
kubectl describe ingress -n l2lab app
kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=100
```

In order of frequency:
1. Public subnets missing `kubernetes.io/role/elb=1`.
2. IRSA broken — trust policy does not match the ServiceAccount.
3. No ACM certificate matching the Ingress `host`.
4. cert-manager not ready, so the controller's admission webhook has no cert.

### 502 from the ALB

The ALB is fine; it has no healthy target.

```sh
kubectl get pods -n l2lab -l app=app
kubectl describe pod -n l2lab -l app=app | grep -A5 Conditions
```

If pods are `Running` but `0/1` Ready, the readiness probe is failing — hit
`/readyz` directly via port-forward to see *which* dependency it names. If
Kubernetes says Ready but the ALB says unhealthy, the ALB health check path or
port is wrong.

### 503 from the ALB

No targets registered at all. Either every pod is down, or the target group is
empty because the controller could not register them.

### Pod stuck `Pending`

```sh
kubectl describe pod -n l2lab <pod>
```

Read the **Events** at the bottom, which say exactly why:
- `Insufficient cpu/memory` → cluster is full; `make wake` or check node count.
- `volume node affinity conflict` → the EBS volume is in a different AZ from
  the only schedulable node.
- `didn't match pod affinity` → topology spread cannot be satisfied.

### Pod `CrashLoopBackOff`

```sh
kubectl logs -n l2lab <pod> --previous
```

`--previous` is essential: it shows the logs of the run that *died*, not the
one currently starting.

- Exit 137 → OOMKilled. Confirm with
  `kubectl describe pod | grep -i -A3 'last state'`.
- Application error on startup → usually a missing env var or an unreachable
  dependency.

### Everyone suddenly logged out

Redis evicted the session keys.

```sh
kubectl exec -n l2lab redis-0 -- redis-cli info stats | grep evicted
kubectl exec -n l2lab redis-0 -- redis-cli info memory | grep used_memory_human
```

`evicted_keys` climbing means `maxmemory` was hit and `allkeys-lru` threw
sessions away along with cache entries.

### Latency is up but dependencies look fine

Look at the dashboard in this order:

1. **CPU throttling** panel — non-zero means a CPU limit is capping the
   container. Presents exactly like a slow application.
2. **Postgres connection pool** — sitting at 10 means requests are queueing for
   a connection. Looks like a slow database; the database is idle.
3. **Cache hit ratio** — a collapse means every read now hits Postgres.

### Timelines are stale but the site works

This is *degraded*, not *down* — the distinction that matters most.

```sh
kubectl logs -n l2lab -l app=worker --tail=50
kubectl get pods -n l2lab -l app=nats
```

Check the **Worker lag** panel. Rising lag with the worker running means it is
slow; no messages at all means NATS is unreachable or the worker is not
subscribed.

### A pod will not start, `CreateContainerConfigError`

Something is using `secretKeyRef` against a Secret that the CSI driver has not
created yet — the ordering problem this repo avoids with the `_FILE` convention.
Check what the pod is asking for:

```sh
kubectl describe pod -n l2lab <pod> | grep -A10 Events
```

### A pod will not start, and the events mention the secrets store

```sh
kubectl describe pod -n l2lab <pod> | tail -25
kubectl logs -n kube-system -l app=secrets-store-csi-driver --tail=50
kubectl get secretproviderclass -A
```

`AccessDeniedException` means IRSA: the ServiceAccount annotation, the role
trust policy, and the role's resource ARN must all agree.

### Everything broke right after `make harden`

A NetworkPolicy. Confirm by reversing it:

```sh
make unharden
```

If that fixes it, re-apply and bisect. The usual culprit is DNS — denying
egress without allowing UDP/TCP 53 to CoreDNS makes every hostname lookup fail,
and the resulting errors point at the wrong component entirely.

```sh
kubectl exec -n l2lab deploy/app -- nslookup postgres.l2lab.svc.cluster.local
```

### `docker push` rejected: tag already exists

The ECR repository uses immutable tags. That SHA has already been pushed.
Commit your changes so the tag changes. This is the feature working.

### Terraform destroy fails on the VPC

An ALB the controller created still holds an ENI in the subnet.

```sh
aws ec2 describe-network-interfaces --region ap-southeast-3 \
  --filters Name=vpc-id,Values=<vpc-id> \
  --query 'NetworkInterfaces[].{id:NetworkInterfaceId,desc:Description}'
```

Delete the Kubernetes Ingress objects, wait a minute for the controller to
remove the ALB, then retry. `make down` already does this in the right order.

---

## Commands worth memorising

```sh
kubectl get events -A --sort-by=.lastTimestamp | tail -40   # what just changed
kubectl describe pod -n <ns> <pod>                          # why is it not running
kubectl logs -n <ns> <pod> --previous                       # why did it die
kubectl top nodes ; kubectl top pods -A                     # actual usage
kubectl get pods -A -o wide --field-selector=status.phase!=Running
```

## After the incident

Every real incident should produce a written record. A usable RCA answers:

- **Timeline** — when it started, when it was detected, when it was resolved.
  Detection time is often the most damning number.
- **Impact** — who was affected, and how. In business terms, not pod counts.
- **Detection** — did monitoring catch it, or did a person?
- **Root cause** — the *underlying* cause, not the symptom. "The pod restarted"
  is a symptom. "The memory limit was set below the working set" is a cause.
- **Contributing factors** — what made it worse or slower to find.
- **Corrective actions** — what stops it recurring, with an owner.

Keep them in `docs/rca/`. The pattern across several of them is worth more
than any single one.
