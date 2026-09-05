locals {
  # e.g. "sawibowo.sandbox.devopsinstitute.id"
  domain = "${var.subdomain}.${var.parent_zone_name}"

  app_fqdn     = "app.${local.domain}"
  grafana_fqdn = "grafana.${local.domain}"

  # The AWS Load Balancer Controller and ExternalDNS both find subnets by tag,
  # not by ID. Get these wrong and the ALB silently never provisions - a very
  # common real-world failure.
  cluster_tag = { "kubernetes.io/cluster/${var.name}" = "shared" }

  # Applied explicitly where `default_tags` cannot reach: EC2 instances and
  # EBS volumes launched by the node group, and volumes created by the CSI
  # driver. Both are invisible to the provider's default_tags.
  common_tags = {
    Project   = var.name
    ManagedBy = "terraform"
    Owner     = var.owner
  }
}
