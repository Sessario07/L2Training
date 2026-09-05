output "cluster_name" { value = aws_eks_cluster.main.name }
output "cluster_endpoint" { value = aws_eks_cluster.main.endpoint }
output "region" { value = var.region }

output "kubeconfig_command" {
  description = "Run this to point kubectl at the new cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name}"
}

output "ecr_repository_urls" {
  description = "One registry URL per image."
  value       = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

# Convenience singles, so the Makefile can `terraform output -raw` them.
output "ecr_api" { value = aws_ecr_repository.app["api"].repository_url }
output "ecr_frontend" { value = aws_ecr_repository.app["frontend"].repository_url }
output "ecr_registry" { value = split("/", aws_ecr_repository.app["api"].repository_url)[0] }
output "acm_certificate_arn" { value = aws_acm_certificate_validation.wildcard.certificate_arn }

output "domain" { value = local.domain }
output "app_url" { value = "https://${local.app_fqdn}" }
output "grafana_url" { value = "https://${local.grafana_fqdn}" }

output "vpc_id" { value = aws_vpc.main.id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }

# These ARNs must be pasted into the ServiceAccount annotations in k8s/.
# The Makefile does the substitution automatically.
output "irsa_role_arns" {
  value = {
    aws_load_balancer_controller = aws_iam_role.aws_lbc.arn
    external_dns                 = aws_iam_role.external_dns.arn
  }
}

# --- Secrets ---------------------------------------------------------------
# ARNs and IRSA roles that the Kubernetes manifests reference. The secret
# VALUES are deliberately not outputs - read them with:
#   aws secretsmanager get-secret-value --secret-id l2lab-sawibowo/grafana \
#     --query SecretString --output text | jq -r '.["admin-password"]'

output "secret_arns" {
  value = {
    postgres = aws_secretsmanager_secret.postgres.arn
    grafana  = aws_secretsmanager_secret.grafana.arn
  }
}

output "secret_names" {
  value = {
    postgres = aws_secretsmanager_secret.postgres.name
    grafana  = aws_secretsmanager_secret.grafana.name
  }
}

output "secrets_irsa_role_arns" {
  value = {
    app     = aws_iam_role.app_secrets.arn
    grafana = aws_iam_role.grafana_secrets.arn
  }
}

output "grafana_admin_password_command" {
  description = "How to retrieve the generated Grafana password."
  value       = "aws secretsmanager get-secret-value --region ${var.region} --secret-id ${aws_secretsmanager_secret.grafana.name} --query SecretString --output text | jq -r '.[\"admin-password\"]'"
}

output "postgres_monitor_secret" {
  value = aws_secretsmanager_secret.postgres_monitor.name
}
