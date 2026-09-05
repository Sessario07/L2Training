# ---------------------------------------------------------------------------
# EKS cluster + managed node group
# ---------------------------------------------------------------------------

# --- Control plane IAM role -------------------------------------------------

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
  tags               = { Name = "${var.name}-cluster" }
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- Cluster ----------------------------------------------------------------

resource "aws_eks_cluster" "main" {
  name     = var.name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    # Control plane ENIs land in the private subnets alongside the nodes.
    subnet_ids = aws_subnet.private[*].id

    # Public endpoint so kubectl works from your laptop without a bastion.
    # Narrow api_public_access_cidrs to lock this down - see variables.tf.
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = var.api_public_access_cidrs
  }

  access_config {
    # API mode replaces the old aws-auth ConfigMap. Access is granted with
    # aws_eks_access_entry resources instead of editing a ConfigMap by hand.
    authentication_mode = "API"

    # Grants cluster-admin to whoever runs `terraform apply` (you).
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Encrypt Kubernetes Secret objects at rest in etcd with a customer-managed
  # KMS key. WARNING: this cannot be removed once enabled - AWS supports
  # turning encryption ON for an existing cluster, never OFF.
  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  # api + authenticator are low-volume and genuinely useful when debugging
  # "why was I denied". `audit` is deliberately OFF: it is very chatty and
  # CloudWatch ingestion is $0.50/GB.
  # `audit` is gated behind a variable because CloudWatch ingestion is
  # $0.50/GB and audit logs are extremely chatty. api + authenticator are
  # low volume and answer "why was I denied", so they are always on.
  enabled_cluster_log_types = var.enable_audit_logs ? ["api", "authenticator", "audit"] : ["api", "authenticator"]

  tags = { Name = var.name }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# --- OIDC provider (the foundation of IRSA) ---------------------------------
# IRSA = IAM Roles for Service Accounts. A pod presents a projected
# ServiceAccount token; STS validates it against this OIDC provider and hands
# back temporary AWS credentials. If the trust policy below does not match the
# ServiceAccount exactly, you get AccessDenied - one of the most common
# real-world EKS failures.

data "tls_certificate" "oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "main" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
}

locals {
  oidc_arn = aws_iam_openid_connect_provider.main.arn
  # e.g. oidc.eks.ap-southeast-3.amazonaws.com/id/ABC123
  oidc_host = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

# --- Node IAM role ----------------------------------------------------------

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = { Name = "${var.name}-node" }
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    # Lets you `aws ssm start-session` onto a node without SSH or a bastion.
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# --- Launch template --------------------------------------------------------
#
# EKS managed node groups do NOT propagate their tags to the EC2 instances they
# launch. Without a launch template, your two largest cost line items - the
# instances and their root volumes - carry no Owner or Project tag at all,
# which makes cost attribution impossible in an account shared with ~30 people.
#
# Deliberately minimal: no image_id and no user_data, so EKS continues to
# manage the AMI and bootstrap exactly as it would without a template. The only
# things being added are tags, disk configuration and IMDSv2.

resource "aws_launch_template" "node" {
  name_prefix = "${var.name}-node-"
  description = "Node template for ${var.name} - tags, EBS config and IMDSv2"

  # Root volume. This moves here from the node group's `disk_size`, which
  # cannot be set at the same time as a launch template.
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # IMDSv2 required. With IMDSv1 available, any server-side request forgery in
  # a pod that reaches 169.254.169.254 can read the NODE's IAM credentials -
  # which are far more privileged than any pod's. hop_limit = 2 is needed so
  # containers (one network hop away) can still reach IMDS for IRSA.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  monitoring {
    enabled = false # detailed CloudWatch monitoring costs extra
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${var.name}-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.common_tags, { Name = "${var.name}-node-root" })
  }

  tag_specifications {
    resource_type = "network-interface"
    tags          = merge(local.common_tags, { Name = "${var.name}-node" })
  }

  tags = { Name = "${var.name}-node" }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Managed node group -----------------------------------------------------

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.name}-ng"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id

  # SPOT: roughly 70% cheaper than on-demand. Interruptions are possible;
  # multiple instance types below let AWS pick from whichever pool has capacity.
  capacity_type  = "SPOT"
  instance_types = var.node_instance_types

  # Amazon Linux 2023, arm64 - matches the Graviton instance types.
  ami_type  = "AL2023_ARM_64_STANDARD"
  disk_size = 30

  # NO custom launch template. Attaching one makes EKS issue RunInstances as
  # ON-DEMAND rather than spot, and this sandbox account has a guardrail that
  # denies on-demand launches:
  #
  #   UnauthorizedOperation on RunInstances, condition
  #   ec2:InstanceMarketType = on-demand
  #
  # AWS also documents that instance_market_options must NOT be set in a
  # launch template for a managed node group - capacity_type on the node group
  # is the supported mechanism, and the two conflict.
  #
  # Consequence: instance and root-volume tagging cannot come from a launch
  # template here. The instances still carry eks:cluster-name,
  # eks:nodegroup-name and kubernetes.io/cluster/<name>, which is enough to
  # identify them. See scripts/tag-nodes.sh for the Project/Owner tags.

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    workload = "general"
  }

  tags = { Name = "${var.name}-ng" }

  lifecycle {
    # The desired size drifts when anything scales the ASG; do not fight it.
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}
