# Ansible

## What Ansible is and is not doing here

It is **not** managing Kubernetes manifests. Kustomize does that, and replacing
it with Jinja-templated YAML would be a step backwards — you would lose
`kubectl diff`, strategic merge patches, and the property that what is in the
repo matches what `kubectl get -o yaml` returns.

It is **not** managing AWS resources. Terraform does that, with a state file
and a dependency graph. Ansible has no equivalent, so using it for
infrastructure would mean giving up plan/apply and reliable teardown.

What it *is* doing, and what it is genuinely better at than a Makefile:

| | Why Ansible |
|---|---|
| **Orchestration** (`site.yml`) | Real idempotency — it will not rebuild an image already in ECR, and uses `terraform plan -detailed-exitcode` so a no-op run reports *no change* instead of re-applying. Retries on the genuinely flaky steps. |
| **Verification** (`verify.yml`) | Turns the runbook's manual checks into assertions. Pass/fail beats "that output looks about right", and re-running the whole set takes thirty seconds. |
| **Day-2 operations** (`ops/`) | Multi-step procedures with ordering constraints, guard rails and confirmation prompts. This is exactly the *"write and refine automation scripts to resolve or prevent recurring issues"* part of an L2 role. |

## Setup

```sh
ansible-galaxy collection install -r requirements.yml

# The interpreter Ansible uses needs these:
ansible --version | grep 'python version'
<that-python> -m pip install kubernetes boto3
```

## Playbooks

```sh
# Build everything
ansible-playbook site.yml
ansible-playbook site.yml --check          # terraform plan only
ansible-playbook site.yml --tags app       # redeploy just the application

# Prove it works
ansible-playbook verify.yml
```

### Day-2 operations

```sh
# Collect a full evidence snapshot — run this FIRST during an incident
ansible-playbook ops/diagnostics.yml

# Backups
ansible-playbook ops/backup-db.yml
ansible-playbook ops/restore-db.yml -e confirm=yes
ansible-playbook ops/restore-db.yml -e confirm=yes \
  -e backup_key=postgres/l2lab-20260829T020000Z.dump

# Secret rotation
ansible-playbook ops/rotate-secrets.yml -e target=grafana  -e confirm=yes
ansible-playbook ops/rotate-secrets.yml -e target=postgres -e confirm=yes

# Cost control
ansible-playbook ops/scale.yml -e state=status
ansible-playbook ops/scale.yml -e state=sleep
ansible-playbook ops/scale.yml -e state=wake

# Destroy, in the order that actually works
ansible-playbook ops/teardown.yml -e confirm=yes
```

## The two playbooks worth reading even if you never run them

**`ops/diagnostics.yml`** — collects a consistent snapshot in about twenty
seconds: events, pod state, resource usage, ALB target health, Route53, and
crucially `kubectl logs --previous` for anything that has restarted. During an
incident, evidence rotates away while you are still forming a hypothesis: pods
restart, logs roll, events expire after an hour. Capture first, investigate
second.

**`ops/teardown.yml`** — encodes the ordering that makes a destroy work.
Kubernetes Ingress objects must go *before* Terraform, because the ALB that the
controller created holds ENIs in the VPC subnets and Terraform has no idea it
exists. Skip that ordering and the destroy hangs for twenty minutes and then
fails. This is one of the most common real-world Terraform-on-EKS failures.

## Conventions

- **`localhost` only.** There is nothing to SSH into; every task talks to the
  AWS or Kubernetes API from your machine. Ansible is the orchestrator, not a
  configuration-management agent.
- **Destructive playbooks require `-e confirm=yes`.** No exceptions.
- **`no_log: true` on anything handling a password.** Otherwise the value ends
  up in your terminal scrollback and in any CI log.
- **Variables live in `group_vars/all.yml`** and must agree with
  `terraform/variables.tf`.
