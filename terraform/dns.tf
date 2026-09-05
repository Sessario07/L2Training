# ---------------------------------------------------------------------------
# DNS + TLS
#
# The Route53 zone is pre-existing and SHARED with ~30 other learners. We only
# read it, then create records underneath our own subdomain.
# ---------------------------------------------------------------------------

data "aws_route53_zone" "parent" {
  name         = "${var.parent_zone_name}."
  private_zone = false
}

# One wildcard certificate covers app.<sub> and grafana.<sub> and anything else
# we add later, so we never wait on certificate validation again.
resource "aws_acm_certificate" "wildcard" {
  domain_name       = "*.${local.domain}"
  validation_method = "DNS"

  # Also cover the apex, so https://<subdomain>.sandbox... works.
  subject_alternative_names = [local.domain]

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = var.name }
}

# ACM asks us to prove domain ownership by publishing a CNAME it specifies.
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.parent.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# Blocks until ACM has actually seen the records and issued the certificate.
# Typically under two minutes.
resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}
