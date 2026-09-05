# l2lab - reproducible EKS training environment
#
#   make up        build everything from nothing (~20 min, mostly EKS)
#   make down      destroy everything (~15 min)
#
# Nothing here is magic; every target is a command you could run by hand.
# Read the recipe before running it.

SHELL        := /bin/bash
.SHELLFLAGS  := -eu -o pipefail -c
.DEFAULT_GOAL := help

REGION       := ap-southeast-3
CLUSTER      := l2lab-sawibowo
TF           := terraform -chdir=terraform
# Immutable tag: the git sha if this is a repo, otherwise a timestamp.
# NEVER deploy :latest - you lose the ability to say what is actually running.
TAG          ?= $(shell git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d-%H%M%S)

# Resolved lazily from terraform outputs, so these are cheap if unused.
ECR_API       = $(shell $(TF) output -raw ecr_api 2>/dev/null)
ECR_FE        = $(shell $(TF) output -raw ecr_frontend 2>/dev/null)
ECR_REGISTRY  = $(shell $(TF) output -raw ecr_registry 2>/dev/null)
VPC_ID        = $(shell $(TF) output -raw vpc_id 2>/dev/null)
APP_URL       = $(shell $(TF) output -raw app_url 2>/dev/null)
GRAFANA_URL   = $(shell $(TF) output -raw grafana_url 2>/dev/null)

BLUE  := \033[36m
BOLD  := \033[1m
OFF   := \033[0m

## ---------------------------------------------------------------- help

help: ## Show this help
	@echo ""
	@printf "$(BOLD)l2lab$(OFF) - EKS training environment\n\n"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(BLUE)%-18s$(OFF) %s\n", $$1, $$2}'
	@echo ""

## ------------------------------------------------------- infrastructure

bootstrap: ## Create the S3 bucket that stores terraform state (run once)
	terraform -chdir=terraform/bootstrap init -input=false
	terraform -chdir=terraform/bootstrap apply -auto-approve

vendor: ## Download the AWS Load Balancer Controller manifests + IAM policy
	@mkdir -p terraform/policies k8s/platform/aws-lbc
	curl -sSfL -o terraform/policies/aws-lbc-iam-policy.json \
	  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.4/docs/install/iam_policy.json
	curl -sSfL -o k8s/platform/aws-lbc/upstream.yaml \
	  https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases/download/v2.13.4/v2_13_4_full.yaml
	@echo "vendored $$(wc -l < k8s/platform/aws-lbc/upstream.yaml) lines of manifests"

init: ## terraform init
	$(TF) init -input=false

plan: init ## Show what terraform would change
	$(TF) plan

infra: init ## Create the AWS infrastructure (VPC, EKS, ALB IAM, ACM, ECR)
	$(TF) apply -auto-approve
	@$(MAKE) --no-print-directory kubeconfig

kubeconfig: ## Point kubectl at the cluster
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER)
	kubectl config set-context --current --namespace=l2lab

## ------------------------------------------------------------ the app

login: ## Authenticate docker against ECR
	aws ecr get-login-password --region $(REGION) \
	  | docker login --username AWS --password-stdin $(ECR_REGISTRY)

build: ## Build both images for arm64
	@test -n "$(ECR_API)" || { echo "no ECR url - run 'make infra' first"; exit 1; }
	# Only the immutable SHA tag. The repositories are IMMUTABLE, so pushing
	# :latest a second time would fail - by design. Deploying :latest also
	# makes "what is running?" unanswerable during an incident.
	docker build --platform linux/arm64 --build-arg TARGETARCH=arm64 \
	  -t $(ECR_API):$(TAG) ./app
	docker build --platform linux/arm64 \
	  -t $(ECR_FE):$(TAG) ./frontend

push: login build ## Build and push both images to ECR
	docker push $(ECR_API):$(TAG)
	docker push $(ECR_FE):$(TAG)
	@echo "pushed $(ECR_API):$(TAG)"
	@echo "pushed $(ECR_FE):$(TAG)"

push-frontend: login ## Rebuild and push ONLY the frontend (fast iteration)
	docker build --platform linux/arm64 -t $(ECR_FE):$(TAG) ./frontend
	docker push $(ECR_FE):$(TAG)
	@./scripts/set-image.py k8s/app l2lab-frontend=$(ECR_FE):$(TAG)
	kubectl apply -k k8s/app
	kubectl -n l2lab rollout status deploy/frontend --timeout=3m

## --------------------------------------------------------------- helm

# The chart is the GitOps-ready path: everything that changes per-build is a
# value, so ArgoCD can render the same chart from git. `make deploy` (below)
# still drives the older k8s/ Kustomize tree and is kept as a fallback.

chart-deps: ## Fetch the chart's subchart dependencies
	helm dependency update ./chart

chart-lint: chart-deps ## Lint and render the chart without a cluster
	helm lint ./chart \
	  --set global.vpcId=vpc-0000000000000000 \
	  --set app.image.tag=lint --set frontend.image.tag=lint
	@helm template l2lab ./chart -n kube-system \
	  --set global.vpcId=vpc-0000000000000000 \
	  --set app.image.tag=lint --set frontend.image.tag=lint \
	  --set hardening.enabled=true > /dev/null && echo "  template renders clean"

chart-install: chart-deps push ## Install/upgrade the chart directly (no ArgoCD)
	@test -n "$(VPC_ID)" || { echo "no vpc_id - run 'make infra' first"; exit 1; }
	helm upgrade --install l2lab ./chart \
	  -n kube-system --create-namespace \
	  --set global.vpcId=$(VPC_ID) \
	  --set aws-load-balancer-controller.vpcId=$(VPC_ID) \
	  --set app.image.tag=$(TAG) \
	  --set frontend.image.tag=$(TAG)
	@$(MAKE) --no-print-directory urls

chart-values: ## Print the --set flags ArgoCD or helm needs right now
	@echo "global.vpcId=$(VPC_ID)"
	@echo "aws-load-balancer-controller.vpcId=$(VPC_ID)"
	@echo "app.image.tag=$(TAG)"
	@echo "frontend.image.tag=$(TAG)"

## --------------------------------------------------------- kubernetes

deploy: ## Apply all Kubernetes manifests, in dependency order
	@test -f k8s/platform/aws-lbc/upstream.yaml || { echo "run 'make vendor' first"; exit 1; }

	@echo "==> namespaces and storage class"
	kubectl apply -k k8s/base

	@echo "==> platform (load balancer controller, external-dns)"
	# The controller needs an explicit --aws-vpc-id, and the VPC id changes on
	# every rebuild. Stamping it here keeps the repo reproducible; a stale id
	# makes every Ingress silently never get an ALB.
	@./scripts/set-vpc.py $$($(TF) output -raw vpc_id)
	kubectl apply -k k8s/platform --server-side --force-conflicts
	kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=5m
	kubectl -n kube-system rollout status deploy/external-dns --timeout=3m

	@echo "==> data layer (postgres, redis, nats)"
	kubectl apply -k k8s/data
	kubectl -n l2lab rollout status sts/postgres --timeout=5m
	kubectl -n l2lab rollout status sts/redis --timeout=3m
	kubectl -n l2lab rollout status deploy/nats --timeout=3m

	@echo "==> observability (prometheus, loki, tempo, grafana, alloy)"
	kubectl apply -k k8s/observability
	kubectl -n observability rollout status sts/prometheus --timeout=5m
	kubectl -n observability rollout status sts/grafana --timeout=5m

	@echo "==> application"
	@./scripts/set-image.py k8s/app l2lab-app=$(ECR_API):$(TAG) l2lab-frontend=$(ECR_FE):$(TAG)
	kubectl apply -k k8s/app
	# Record WHY each rollout happened. Without this, `kubectl rollout history`
	# prints a column of <none> and tells you nothing - which is exactly when
	# you need it, mid-incident, deciding which revision to roll back to.
	@for d in app frontend worker; do \
	  kubectl -n l2lab annotate deployment/$$d --overwrite \
	    kubernetes.io/change-cause="make deploy tag=$(TAG) at $$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null; \
	done
	kubectl -n l2lab rollout status deploy/app --timeout=5m
	kubectl -n l2lab rollout status deploy/frontend --timeout=3m
	kubectl -n l2lab rollout status deploy/worker --timeout=3m

	@$(MAKE) --no-print-directory urls

up: ## Full build: infra, image, manifests
	@$(MAKE) --no-print-directory vendor
	@$(MAKE) --no-print-directory infra
	@$(MAKE) --no-print-directory push
	@$(MAKE) --no-print-directory deploy

history: ## Show what image each deployment revision used
	@for d in app frontend worker; do \
	  echo "=== $$d ==="; \
	  kubectl -n l2lab get rs -l app=$$d --sort-by=.metadata.creationTimestamp \
	    -o custom-columns='REV:.metadata.annotations.deployment\.kubernetes\.io/revision,REPLICAS:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image' 2>/dev/null; \
	done

redeploy: push ## Rebuild both images and roll the workloads
	@./scripts/set-image.py k8s/app l2lab-app=$(ECR_API):$(TAG) l2lab-frontend=$(ECR_FE):$(TAG)
	kubectl apply -k k8s/app
	kubectl -n l2lab rollout status deploy/app --timeout=5m
	kubectl -n l2lab rollout status deploy/frontend --timeout=3m
	kubectl -n l2lab rollout status deploy/worker --timeout=3m

harden: ## Apply NetworkPolicy, quotas and the backup CronJob (AFTER the stack is green)
	@echo "Applying segmentation and quotas."
	@echo "Do this only once everything is already healthy - a wrong"
	@echo "NetworkPolicy looks exactly like a DNS or dependency failure."
	kubectl apply -k k8s/hardening
	@echo ""
	@echo "Verify nothing broke:  make status  &&  ansible-playbook ansible/verify.yml"

unharden: ## Remove the hardening layer (to isolate whether it broke something)
	kubectl delete -k k8s/hardening --ignore-not-found

verify: ## Run the full verification suite
	cd ansible && ansible-playbook verify.yml

diagnose: ## Collect a full evidence snapshot for an incident/RCA
	cd ansible && ansible-playbook ops/diagnostics.yml

## --------------------------------------------------------------- chaos

chaos: ## List the RCA practice scenarios
	@python3 chaos/chaos.py list

break: ## Inject a RANDOM fault (you are not told which)
	@python3 chaos/chaos.py break

hint: ## One nudge on the active fault
	@python3 chaos/chaos.py hint

reveal: ## Show the root cause of the active fault
	@python3 chaos/chaos.py reveal

fix: ## Restore, and record your time to resolution
	@python3 chaos/chaos.py fix

## ------------------------------------------------------------- operate

urls: ## Print the public URLs
	@echo ""
	@printf "  app     $(BOLD)%s$(OFF)\n" "$(APP_URL)"
	@printf "  grafana $(BOLD)%s$(OFF)  (admin / see 'make password')\n" "$(GRAFANA_URL)"
	@echo ""
	@echo "  DNS can take 1-2 minutes to propagate after the ALB appears."
	@echo ""

password: ## Print the generated Grafana admin password
	@aws secretsmanager get-secret-value --region $(REGION) \
	  --secret-id $(CLUSTER)/grafana --query SecretString --output text \
	  | jq -r '."admin-password"'

status: ## One-screen health summary
	@echo "=== nodes ==="
	@kubectl get nodes -o wide
	@echo ""
	@echo "=== l2lab ==="
	@kubectl get pods -n l2lab -o wide
	@echo ""
	@echo "=== observability ==="
	@kubectl get pods -n observability -o wide
	@echo ""
	@echo "=== ingress ==="
	@kubectl get ingress -A
	@echo ""
	@echo "=== not-ready pods, if any ==="
	@kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null || true

logs: ## Tail the application logs
	kubectl logs -n l2lab -l app=app --tail=50 -f --max-log-requests=10

events: ## Recent cluster events, newest last
	kubectl get events -A --sort-by=.lastTimestamp | tail -40

grafana: ## Port-forward Grafana to localhost:3000 (works without DNS)
	@echo "http://localhost:3000  (admin / l2lab-admin)"
	kubectl -n observability port-forward svc/grafana 3000:3000

prometheus: ## Port-forward Prometheus to localhost:9090
	@echo "http://localhost:9090"
	kubectl -n observability port-forward svc/prometheus 9090:9090

restart-grafana: ## Reload Grafana after editing datasources.yaml
	kubectl -n observability rollout restart sts/grafana
	kubectl -n observability rollout status sts/grafana --timeout=3m

psql: ## Open a psql shell on the database
	kubectl exec -it -n l2lab postgres-0 -- psql -U l2lab -d l2lab

redis-cli: ## Open a redis-cli shell
	kubectl exec -it -n l2lab redis-0 -- redis-cli

seed: ## Create demo users, follows and posts
	./scripts/seed.sh "$(APP_URL)"

load: ## Generate continuous traffic so the dashboards have data
	./scripts/loadgen.sh "$(APP_URL)"

## --------------------------------------------------------------- cost

sleep: ## Scale the node group to zero (keeps state, stops most of the cost)
	aws eks update-nodegroup-config --region $(REGION) \
	  --cluster-name $(CLUSTER) --nodegroup-name $(CLUSTER)-ng \
	  --scaling-config minSize=0,maxSize=3,desiredSize=0
	@echo "nodes scaling to zero. control plane, NAT and EBS still bill (~\$$0.16/hr)."

wake: ## Scale the node group back up
	aws eks update-nodegroup-config --region $(REGION) \
	  --cluster-name $(CLUSTER) --nodegroup-name $(CLUSTER)-ng \
	  --scaling-config minSize=2,maxSize=3,desiredSize=2
	@echo "nodes coming back. give it ~3 minutes, then: make status"

inventory: ## List every AWS resource this environment created
	@./scripts/inventory.sh

cost: ## Show month-to-date spend on this account
	@aws ce get-cost-and-usage --region us-east-1 \
	  --time-period Start=$$(date -u +%Y-%m-01),End=$$(date -u -v+1d +%Y-%m-%d) \
	  --granularity MONTHLY --metrics UnblendedCost \
	  --query 'ResultsByTime[0].Total.UnblendedCost.Amount' --output text \
	  | xargs printf "account month-to-date: \$$%.2f\n"

## ------------------------------------------------------------- destroy

guard: ## Refuse to run destructive commands against the wrong cluster
	@ctx=$$(kubectl config current-context 2>/dev/null); \
	  case "$$ctx" in \
	    *$(CLUSTER)*) echo "  context OK: $$ctx" ;; \
	    *) echo ""; \
	       echo "  REFUSING: kubectl context is '$$ctx'"; \
	       echo "  expected it to contain '$(CLUSTER)'."; \
	       echo "  This AWS account is shared with ~30 other learners - a"; \
	       echo "  teardown against the wrong cluster destroys their work."; \
	       echo "  Fix with: make kubeconfig"; \
	       echo ""; exit 1 ;; \
	  esac
	@acct=$$(aws sts get-caller-identity --query Account --output text 2>/dev/null); \
	  test "$$acct" = "134604498185" || { echo "  REFUSING: wrong AWS account $$acct"; exit 1; }
	@echo "  account OK: 134604498185"

down: guard ## Destroy everything
	@echo "Deleting Kubernetes objects that own AWS resources first."
	@echo "Skipping this orphans the ALB and its Route53 records, and then the"
	@echo "VPC refuses to delete because an ENI is still attached to it."
	-kubectl delete -k k8s/hardening --ignore-not-found --timeout=3m
	-kubectl delete -k k8s/app --ignore-not-found --timeout=3m
	-kubectl delete ingress -n observability grafana --ignore-not-found --timeout=3m
	-kubectl delete -k k8s/observability --ignore-not-found --timeout=5m
	-kubectl delete -k k8s/data --ignore-not-found --timeout=5m

	# PVCs created from a StatefulSet's volumeClaimTemplates are DELIBERATELY
	# not garbage-collected when the StatefulSet is deleted - Kubernetes keeps
	# them so you can recreate the StatefulSet and get your data back.
	#
	# That means deleting the StatefulSets is NOT enough: the EBS volumes
	# survive, detach, sit in `available`, and keep billing. The StorageClass
	# has reclaimPolicy: Delete, so deleting the PVC is what removes the disk.
	#
	# This step was missing and leaked 37 GB across 7 volumes on the first
	# teardown. `make orphans` caught it.
	@echo "Deleting PVCs (StatefulSet volumes are not auto-removed)..."
	-kubectl delete pvc --all -n l2lab --ignore-not-found --timeout=3m
	-kubectl delete pvc --all -n observability --ignore-not-found --timeout=3m

	@echo "Waiting 60s for the load balancer controller to tear down the ALB..."
	@sleep 60
	-kubectl delete -k k8s/platform --ignore-not-found --timeout=3m
	$(TF) destroy -auto-approve
	@echo ""
	@echo "Done. Verify nothing was left behind:  make orphans"

orphans: ## Check for leftover AWS resources after a destroy
	@echo "=== load balancers tagged for this project ==="
	@aws elbv2 describe-load-balancers --region $(REGION) \
	  --query "LoadBalancers[?contains(LoadBalancerName, 'l2lab')].LoadBalancerName" --output text || true
	@echo "=== VPCs ==="
	@aws ec2 describe-vpcs --region $(REGION) \
	  --filters Name=tag:Project,Values=$(CLUSTER) \
	  --query 'Vpcs[].VpcId' --output text || true
	@echo "=== route53 records under our subdomain ==="
	@aws route53 list-resource-record-sets --hosted-zone-id Z0646008ZGZY2INOOAOG \
	  --query "ResourceRecordSets[?contains(Name, 'sawibowo')].Name" --output text || true
	@echo "=== EBS volumes ==="
	@aws ec2 describe-volumes --region $(REGION) \
	  --filters Name=status,Values=available \
	  --query 'Volumes[?Tags[?Key==`kubernetes.io/cluster/$(CLUSTER)`]].VolumeId' --output text || true

## ---------------------------------------------------------------- lint

check: ## Validate everything without touching AWS
	@echo "=== terraform fmt ==="
	@$(TF) fmt -check -recursive || { echo "run: terraform fmt -recursive terraform/"; exit 1; }
	@echo "=== terraform validate ==="
	@$(TF) validate
	@echo "=== go ==="
	@cd app && go vet ./... && go build ./...
	@echo "=== kustomize builds ==="
	@for d in k8s/base k8s/data k8s/observability k8s/app k8s/hardening; do \
	  printf "  %-22s" "$$d"; \
	  kubectl kustomize $$d > /dev/null && echo "ok"; \
	done
	@echo "=== name consistency (terraform vs k8s manifests) ==="
	@tfname=$$(grep -A3 'variable "name"' terraform/variables.tf | grep default | cut -d'"' -f2); \
	  bad=$$(grep -rlE 'l2lab-sawibowo' k8s/ 2>/dev/null | wc -l | tr -d ' '); \
	  if [ "$$tfname" != "$(CLUSTER)" ]; then \
	    echo "  MISMATCH: terraform var.name='$$tfname' but Makefile CLUSTER='$(CLUSTER)'"; exit 1; \
	  fi; \
	  if ! grep -rq "$$tfname" k8s/data/secrets/secretproviderclass.yaml; then \
	    echo "  MISMATCH: k8s manifests do not reference '$$tfname'."; \
	    echo "  The IAM role ARNs and secret paths in k8s/ are LITERAL strings -"; \
	    echo "  Kustomize cannot read terraform outputs. Renaming var.name means"; \
	    echo "  updating these $$bad files too, or pods get AccessDenied at runtime."; \
	    exit 1; \
	  fi; \
	  echo "  ok - terraform, Makefile and k8s manifests all agree on '$$tfname'"

	@echo "=== helm chart ==="
	@helm lint ./chart --set global.vpcId=vpc-0 --set app.image.tag=l --set frontend.image.tag=l 2>&1 | tail -1 | sed 's/^/  /'
	@helm template l2lab ./chart -n kube-system --set global.vpcId=vpc-0 --set app.image.tag=l --set frontend.image.tag=l --set hardening.enabled=true >/dev/null && echo "  template renders clean"

	@echo "=== ansible syntax ==="
	@cd ansible && for p in site.yml verify.yml ops/*.yml; do \
	  printf "  %-24s" "$$p"; ansible-playbook --syntax-check $$p >/dev/null 2>&1 \
	    && echo "ok" || { echo "FAILED"; exit 1; }; \
	done
	@echo "all checks passed"

.PHONY: help bootstrap vendor init plan infra kubeconfig login build push \
        deploy up redeploy urls status logs events grafana prometheus psql \
        redis-cli seed load sleep wake cost down orphans check restart-grafana push-frontend \
        harden unharden verify diagnose password chaos break hint reveal fix inventory history guard chart-deps chart-lint chart-install chart-values
