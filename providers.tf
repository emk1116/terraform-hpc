provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "titan-hpc"
      Team      = var.team_name
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}
