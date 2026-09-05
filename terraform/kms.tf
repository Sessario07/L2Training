# ---------------------------------------------------------------------------
# KMS - envelope encryption for Kubernetes Secrets at rest
#
# By default, EKS stores Secret objects in etcd base64-encoded but NOT
# encrypted. Envelope encryption means each Secret is encrypted with a data key
# that is itself encrypted by this KMS key, so an etcd snapshot is useless on
# its own.
#
# Cost: $1/month for the key, plus $0.03 per 10,000 requests. For a weekend,
# roughly 10 cents.
# ---------------------------------------------------------------------------

resource "aws_kms_key" "eks" {
  description             = "Envelope encryption for ${var.name} Kubernetes secrets"
  enable_key_rotation     = true
  deletion_window_in_days = 7 # the minimum AWS allows

  tags = { Name = "${var.name}-eks" }
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}
