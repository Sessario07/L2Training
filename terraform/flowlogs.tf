# ---------------------------------------------------------------------------
# VPC Flow Logs (optional - set enable_flow_logs = true)
#
# Flow logs record accepted and rejected connections at the ENI level. During a
# connectivity incident they are what let you prove whether traffic ever
# reached the instance, which separates "security group is blocking it" from
# "the application is not listening" - two problems with identical symptoms.
#
# Written to S3 rather than CloudWatch Logs: roughly 10x cheaper for data you
# query rarely.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  bucket        = "${var.name}-flowlogs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = { Name = "${var.name}-flowlogs" }
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  bucket                  = aws_s3_bucket.flow_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  bucket = aws_s3_bucket.flow_logs[0].id

  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration { days = 7 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

resource "aws_flow_log" "vpc" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id               = aws_vpc.main.id
  log_destination      = aws_s3_bucket.flow_logs[0].arn
  log_destination_type = "s3"

  # ALL, not just REJECT. Accepted traffic is what tells you a connection was
  # established but the application never answered.
  traffic_type = "ALL"

  # 1 minute instead of the 10-minute default, so logs are useful while an
  # incident is still happening rather than long after it is resolved.
  max_aggregation_interval = 60

  tags = { Name = "${var.name}" }
}
