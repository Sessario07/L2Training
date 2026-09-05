terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }

  # S3 native state locking (Terraform >= 1.10) - no DynamoDB table needed.
  backend "s3" {
    bucket       = "l2lab-sawibowo-tfstate-134604498185"
    key          = "l2lab/terraform.tfstate"
    region       = "ap-southeast-3"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = var.name
      ManagedBy = "terraform"
      Owner     = var.owner
    }
  }
}
