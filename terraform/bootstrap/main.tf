# Bootstrap: creates the S3 bucket that holds Terraform state for the main stack.
# Run this ONCE, with local state, before the main stack.
#   cd terraform/bootstrap && terraform init && terraform apply
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "ap-southeast-3"
}

variable "state_bucket" {
  type    = string
  default = "l2lab-sawibowo-tfstate-134604498185"
}

resource "aws_s3_bucket" "state" {
  bucket        = var.state_bucket
  force_destroy = true # lab convenience: allows `terraform destroy` to clean up
}

# Versioning lets us recover if a state write goes wrong.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "state_bucket" { value = aws_s3_bucket.state.id }
