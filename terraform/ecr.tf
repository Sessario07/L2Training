# ---------------------------------------------------------------------------
# Container registries
#
# TWO repositories, not one. The frontend and the API are separate images with
# independent lifecycles: either can be rolled back without touching the other,
# and a bad frontend push cannot take the API down.
#
# ECR repository names may contain slashes, so they read as a namespace.
# ---------------------------------------------------------------------------

locals {
  ecr_repos = ["api", "frontend"]
}

resource "aws_ecr_repository" "app" {
  for_each = toset(local.ecr_repos)

  name = "${var.name}/${each.key}"

  # IMMUTABLE tags: once pushed, a tag can never be repointed at a different
  # image. This is what makes "which code is running?" answerable during an
  # incident. It is also why the Makefile tags with a git SHA rather than
  # :latest - re-pushing :latest would now fail, by design.
  image_tag_mutability = "IMMUTABLE"

  # Lets `terraform destroy` remove the repo even with images still in it.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = { Name = "${var.name}-${each.key}" }
}

# Keep only the most recent images so an untended lab cannot accrue storage cost.
resource "aws_ecr_lifecycle_policy" "app" {
  for_each = aws_ecr_repository.app

  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
