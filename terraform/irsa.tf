# ---------------------------------------------------------------------------
# IRSA - IAM Roles for Service Accounts
#
# How it works, because this is the #1 thing that breaks on EKS:
#
#   1. A pod mounts a projected ServiceAccount JWT at
#      /var/run/secrets/eks.amazonaws.com/serviceaccount/token
#   2. The AWS SDK calls sts:AssumeRoleWithWebIdentity with that JWT.
#   3. STS validates the JWT signature against the cluster's OIDC provider.
#   4. STS checks the role's trust policy: does the token's `sub` claim
#      (system:serviceaccount:<namespace>:<serviceaccount>) match?
#   5. If yes -> temporary credentials. If no -> AccessDenied.
#
# Step 4 is where mistakes live. The namespace and ServiceAccount name in the
# trust policy below must match the Kubernetes manifests EXACTLY, and the
# ServiceAccount must carry the eks.amazonaws.com/role-arn annotation.
# ---------------------------------------------------------------------------

# --- EBS CSI driver ---------------------------------------------------------
# Needs permission to create/attach/detach EBS volumes when a PVC is created.

data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
  tags               = { Name = "${var.name}-ebs-csi" }
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# --- ExternalDNS ------------------------------------------------------------
# Watches Ingress/Service objects and writes matching Route53 records.

data "aws_iam_policy_document" "external_dns_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:kube-system:external-dns"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_dns" {
  name               = "${var.name}-external-dns"
  assume_role_policy = data.aws_iam_policy_document.external_dns_assume.json
  tags               = { Name = "${var.name}-external-dns" }
}

data "aws_iam_policy_document" "external_dns" {
  # Write records - scoped to the ONE shared zone, so a misconfiguration here
  # cannot stomp on the other ~30 learners' DNS records.
  statement {
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [data.aws_route53_zone.parent.arn]
  }

  # Discovery - must be account-wide, the API does not support resource scoping.
  statement {
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "external_dns" {
  name   = "route53"
  role   = aws_iam_role.external_dns.id
  policy = data.aws_iam_policy_document.external_dns.json
}

# --- AWS Load Balancer Controller -------------------------------------------
# Creates and manages the ALB from Ingress resources. The policy JSON is the
# canonical one published by the upstream project (see policies/README.md).

data "aws_iam_policy_document" "aws_lbc_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "aws_lbc" {
  name               = "${var.name}-aws-lbc"
  assume_role_policy = data.aws_iam_policy_document.aws_lbc_assume.json
  tags               = { Name = "${var.name}-aws-lbc" }
}

resource "aws_iam_policy" "aws_lbc" {
  name   = "${var.name}-aws-lbc"
  policy = file("${path.module}/policies/aws-lbc-iam-policy.json")
  tags   = { Name = "${var.name}-aws-lbc" }
}

resource "aws_iam_role_policy_attachment" "aws_lbc" {
  role       = aws_iam_role.aws_lbc.name
  policy_arn = aws_iam_policy.aws_lbc.arn
}
