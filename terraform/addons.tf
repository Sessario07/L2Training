# ---------------------------------------------------------------------------
# EKS managed addons
#
# These are installed and upgraded by AWS rather than by us. Using them for
# commodity components means far less YAML in this repo. Versions were resolved
# against EKS 1.34 in ap-southeast-3 (see docs/DECISIONS.md).
# ---------------------------------------------------------------------------

# --- Networking (must exist before nodes can run pods) ----------------------

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  # Prefix delegation: without it, a t4g.large is capped at 35 pods because
  # each pod consumes a secondary ENI IP. With it, the node allocates /28
  # prefixes instead and the cap rises to 110. Free, and removes an entire
  # class of "pod stuck in ContainerCreating - no IP addresses" failure.
  # Schema check before editing this block - the addon rejects unknown keys
  # with a 400 and the message is not obvious:
  #   aws eks describe-addon-configuration --addon-name vpc-cni \
  #     --addon-version <v> --query configurationSchema --output text | jq
  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }

    # Required for Kubernetes NetworkPolicy objects to be ENFORCED. Without
    # it they are accepted by the API server and silently do nothing, which
    # is far worse than not having them - you believe you are segmented and
    # you are not.
    enableNetworkPolicy = "true"

    nodeAgent = {
      # Logs every allowed/denied flow decision. This is what turns "the
      # connection just hangs" into an answer when debugging a policy.
      enablePolicyEventLogs = "true"
    }
  })

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# --- Everything below needs a node to schedule onto -------------------------

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

# Provisions EBS volumes for PVCs. Postgres, Prometheus, Loki and Tempo all
# depend on this; without it their pods sit Pending forever.
resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

# Supplies `kubectl top` and the metrics HPAs consume.
resource "aws_eks_addon" "metrics_server" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "metrics-server"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

# Exports Deployment/Pod/Node object state as Prometheus metrics
# (kube_pod_status_phase, kube_deployment_status_replicas, ...).
resource "aws_eks_addon" "kube_state_metrics" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-state-metrics"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

# Per-node CPU/memory/disk/network metrics.
resource "aws_eks_addon" "node_exporter" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "prometheus-node-exporter"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

# The AWS Load Balancer Controller's upstream manifests declare an admission
# webhook whose TLS certificate is issued by cert-manager. Installing
# cert-manager as a managed addon avoids pulling in Helm just for that.
resource "aws_eks_addon" "cert_manager" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "cert-manager"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

# Secrets Store CSI driver + the AWS provider.
#
# This single addon installs BOTH the upstream secrets-store-csi-driver and
# AWS's provider plugin for it (note the nested "secrets-store-csi-driver"
# configuration block), so nothing has to be vendored from upstream.
resource "aws_eks_addon" "secrets_store_csi" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-secrets-store-csi-driver-provider"

  configuration_values = jsonencode({
    awsRegion = var.region

    "secrets-store-csi-driver" = {
      install = true

      # Required for `secretObjects` in a SecretProviderClass to work at all.
      # Off by default, and its absence is a classic silent failure: the volume
      # mounts fine, but no Kubernetes Secret ever appears.
      syncSecret = { enabled = true }

      # Re-read the secret periodically, so a rotation in Secrets Manager
      # reaches the mounted files without redeploying the pod.
      enableSecretRotation = true
      rotationPollInterval = "60s"
    }
  })

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}
