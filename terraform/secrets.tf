# ---------------------------------------------------------------------------
# Secrets
#
# Passwords are GENERATED here and stored in AWS Secrets Manager. They are
# never written into the repository, and nobody - including whoever runs
# terraform - ever needs to see them.
#
# They reach the pods via the Secrets Store CSI driver, which mounts them and
# syncs them into a Kubernetes Secret. See k8s/platform/secrets-store/.
#
# NOTE: the generated values DO land in Terraform state, which is why the state
# bucket is encrypted and access-controlled. That is inherent to Terraform, not
# something this configuration chose. The production alternative is to let
# Secrets Manager generate and rotate the value with a Lambda, and have
# Terraform only reference the ARN.
# ---------------------------------------------------------------------------

resource "random_password" "postgres" {
  length = 32
  # Avoid characters that need escaping inside a Postgres connection URI.
  special          = true
  override_special = "-_=+"
}

# A SEPARATE credential for the metrics exporter. The application role is a
# superuser; giving that to a metrics sidecar means a compromised exporter can
# read every row in the database. Postgres ships a predefined `pg_monitor` role
# for exactly this - it grants the statistics views and nothing else.
resource "random_password" "postgres_monitor" {
  length           = 32
  special          = true
  override_special = "-_=+"
}

resource "random_password" "grafana" {
  length           = 24
  special          = true
  override_special = "-_=+"
}

locals {
  postgres_user = "l2lab"
  postgres_db   = "l2lab"
  postgres_host = "postgres.l2lab.svc.cluster.local"
}

# --- Postgres ---------------------------------------------------------------

resource "aws_secretsmanager_secret" "postgres" {
  name        = "${var.name}/postgres"
  description = "PostgreSQL credentials for ${var.name}"
  tags        = { Name = "${var.name}-postgres" }

  # 0 = delete immediately on destroy. The default is a 30-day recovery window,
  # during which the NAME stays reserved - so a rebuild fails with
  # "already scheduled for deletion". Correct for production, wrong for a lab
  # that gets torn down and recreated repeatedly.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "postgres" {
  secret_id = aws_secretsmanager_secret.postgres.id

  # Stored as JSON so one secret carries several related fields. The CSI
  # driver can extract individual keys with jmesPath.
  secret_string = jsonencode({
    username = local.postgres_user
    password = random_password.postgres.result
    database = local.postgres_db
    host     = local.postgres_host
    port     = "5432"
    # Pre-built connection string, so the application does not have to
    # assemble one (and cannot get the escaping wrong).
    url = format(
      "postgres://%s:%s@%s:5432/%s?sslmode=disable",
      local.postgres_user,
      urlencode(random_password.postgres.result),
      local.postgres_host,
      local.postgres_db,
    )
  })
}

resource "aws_secretsmanager_secret" "postgres_monitor" {
  name                    = "${var.name}/postgres-monitor"
  description             = "Read-only monitoring role for ${var.name} PostgreSQL"
  recovery_window_in_days = 0
  tags                    = { Name = "${var.name}-postgres-monitor" }
}

resource "aws_secretsmanager_secret_version" "postgres_monitor" {
  secret_id = aws_secretsmanager_secret.postgres_monitor.id
  secret_string = jsonencode({
    username = "l2lab_monitor"
    password = random_password.postgres_monitor.result
    # postgres-exporter reads DATA_SOURCE_NAME. Connects over localhost
    # because it runs as a sidecar in the Postgres pod.
    url = format(
      "postgresql://l2lab_monitor:%s@127.0.0.1:5432/%s?sslmode=disable",
      urlencode(random_password.postgres_monitor.result),
      local.postgres_db,
    )
  })
}

# --- Grafana ----------------------------------------------------------------

resource "aws_secretsmanager_secret" "grafana" {
  name                    = "${var.name}/grafana"
  description             = "Grafana admin credentials for ${var.name}"
  tags                    = { Name = "${var.name}-grafana" }
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id = aws_secretsmanager_secret.grafana.id
  secret_string = jsonencode({
    admin-user     = "admin"
    admin-password = random_password.grafana.result
  })
}

# ---------------------------------------------------------------------------
# IRSA roles for reading those secrets
#
# Least privilege, per workload: the application can read the Postgres secret
# and nothing else; Grafana can read its own and nothing else. A compromised
# app pod cannot read Grafana's admin password.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "app_secrets_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      # Multiple values in one StringEquals condition are OR-ed, so this role
      # is assumable by exactly these two ServiceAccounts and no others.
      values = [
        "system:serviceaccount:l2lab:app",
        "system:serviceaccount:l2lab:worker",
        # Postgres reads its own password from the same secret at first boot.
        "system:serviceaccount:l2lab:postgres",
      ]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app_secrets" {
  name               = "${var.name}-app-secrets"
  assume_role_policy = data.aws_iam_policy_document.app_secrets_assume.json
  tags               = { Name = "${var.name}-app-secrets" }
}

data "aws_iam_policy_document" "app_secrets" {
  statement {
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      aws_secretsmanager_secret.postgres.arn,
      # The exporter sidecar and the role-creation Job run in the Postgres pod,
      # under the same ServiceAccount, so they need the monitor credential too.
      aws_secretsmanager_secret.postgres_monitor.arn,
    ]
  }
}

resource "aws_iam_role_policy" "app_secrets" {
  name   = "read-postgres-secret"
  role   = aws_iam_role.app_secrets.id
  policy = data.aws_iam_policy_document.app_secrets.json
}

data "aws_iam_policy_document" "grafana_secrets_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:observability:grafana"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "grafana_secrets" {
  name               = "${var.name}-grafana-secrets"
  assume_role_policy = data.aws_iam_policy_document.grafana_secrets_assume.json
  tags               = { Name = "${var.name}-grafana-secrets" }
}

data "aws_iam_policy_document" "grafana_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.grafana.arn]
  }
}

resource "aws_iam_role_policy" "grafana_secrets" {
  name   = "read-grafana-secret"
  role   = aws_iam_role.grafana_secrets.id
  policy = data.aws_iam_policy_document.grafana_secrets.json
}
