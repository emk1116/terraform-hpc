variable "name_prefix" { type = string }
variable "team_name" { type = string }
variable "initial_repos" {
  type    = list(string)
  default = []
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_ecr_repository" "repos" {
  for_each = toset(var.initial_repos)

  name                 = "${var.team_name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "${var.name_prefix}-${replace(each.key, "/", "-")}"
  }
}

# Lifecycle: keep last 10 versions, expire untagged after 7 days
resource "aws_ecr_lifecycle_policy" "repos" {
  for_each   = aws_ecr_repository.repos
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 10
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
    ]
  })
}

output "registry_url" {
  value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com"
}

output "repository_arns" {
  value = [for r in aws_ecr_repository.repos : r.arn]
}

output "repository_names" {
  value = [for r in aws_ecr_repository.repos : r.name]
}
