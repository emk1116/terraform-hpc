variable "name_prefix" { type = string }
variable "team_name" { type = string }
variable "aws_region" { type = string }
variable "s3_bucket_arn" { type = string }
variable "ecr_repo_arns" { type = list(string) }
variable "secrets_arns" {
  type    = list(string)
  default = []
}
variable "aurora_resource_id" {
  type    = string
  default = null
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ============================================================================
# Assume role policy — shared across all EC2 roles
# ============================================================================

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ============================================================================
# Shared: SSM Session Manager access (for shell access to head/login/compute)
# ============================================================================

data "aws_iam_policy" "ssm_core" {
  arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ============================================================================
# Shared: CloudWatch Logs for agent logging
# ============================================================================

data "aws_iam_policy_document" "cloudwatch_logs" {
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/titan-hpc/${var.team_name}/*"
    ]
  }
}

resource "aws_iam_policy" "cloudwatch_logs" {
  name_prefix = "${var.name_prefix}-cw-logs-"
  policy      = data.aws_iam_policy_document.cloudwatch_logs.json
}

# ============================================================================
# Shared: S3 access to the team's data bucket (scoped, no wildcard)
# ============================================================================

data "aws_iam_policy_document" "s3_access" {
  statement {
    sid       = "ListTeamBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.s3_bucket_arn]
  }

  statement {
    sid = "RwTeamBucketObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${var.s3_bucket_arn}/*"]
  }
}

resource "aws_iam_policy" "s3_access" {
  name_prefix = "${var.name_prefix}-s3-"
  policy      = data.aws_iam_policy_document.s3_access.json
}

# ============================================================================
# Shared: ECR pull (scoped to team's repos)
# ============================================================================

data "aws_iam_policy_document" "ecr_pull" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # This action cannot be scoped, per AWS
  }

  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
    ]
    resources = var.ecr_repo_arns
  }
}

resource "aws_iam_policy" "ecr_pull" {
  name_prefix = "${var.name_prefix}-ecr-"
  policy      = data.aws_iam_policy_document.ecr_pull.json
}

# ============================================================================
# Shared: Secrets Manager read (for DB passwords)
# ============================================================================

data "aws_iam_policy_document" "secrets_read" {
  statement {
    sid     = "ReadDbSecrets"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    # Wildcard on the team's secret names — specific ARNs have random suffixes
    resources = ["arn:aws:secretsmanager:${var.aws_region}:${local.account_id}:secret:${var.name_prefix}-*"]
  }
}

resource "aws_iam_policy" "secrets_read" {
  name_prefix = "${var.name_prefix}-secrets-"
  policy      = data.aws_iam_policy_document.secrets_read.json
}

# ============================================================================
# HEAD NODE role — needs it all (S3, ECR, EC2 run/terminate, Secrets, FSx)
# ============================================================================

resource "aws_iam_role" "head_node" {
  name_prefix        = "${var.name_prefix}-head-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "head_ssm" {
  role       = aws_iam_role.head_node.name
  policy_arn = data.aws_iam_policy.ssm_core.arn
}

resource "aws_iam_role_policy_attachment" "head_cw" {
  role       = aws_iam_role.head_node.name
  policy_arn = aws_iam_policy.cloudwatch_logs.arn
}

resource "aws_iam_role_policy_attachment" "head_s3" {
  role       = aws_iam_role.head_node.name
  policy_arn = aws_iam_policy.s3_access.arn
}

resource "aws_iam_role_policy_attachment" "head_ecr" {
  role       = aws_iam_role.head_node.name
  policy_arn = aws_iam_policy.ecr_pull.arn
}

resource "aws_iam_role_policy_attachment" "head_secrets" {
  role       = aws_iam_role.head_node.name
  policy_arn = aws_iam_policy.secrets_read.arn
}

# Head node's critical extra: ResumeProgram needs ec2:RunInstances
# and ec2:TerminateInstances for the compute fleet
data "aws_iam_policy_document" "head_ec2_fleet" {
  statement {
    sid = "RunInstancesForCompute"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateTags",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
    ]
    resources = ["*"]
  }

  statement {
    sid = "TerminateOnlyOurNodes"
    actions = [
      "ec2:TerminateInstances",
      "ec2:StopInstances",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Team"
      values   = [var.team_name]
    }
  }

  statement {
    sid       = "PassRoleToCompute"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.compute_node.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "head_ec2_fleet" {
  name_prefix = "${var.name_prefix}-head-ec2-"
  policy      = data.aws_iam_policy_document.head_ec2_fleet.json
}

resource "aws_iam_role_policy_attachment" "head_ec2_fleet" {
  role       = aws_iam_role.head_node.name
  policy_arn = aws_iam_policy.head_ec2_fleet.arn
}

resource "aws_iam_instance_profile" "head_node" {
  name_prefix = "${var.name_prefix}-head-"
  role        = aws_iam_role.head_node.name
}

# ============================================================================
# COMPUTE NODE role — S3, ECR, Secrets (optional for model fetching), SSM
# ============================================================================

resource "aws_iam_role" "compute_node" {
  name_prefix        = "${var.name_prefix}-compute-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "compute_ssm" {
  role       = aws_iam_role.compute_node.name
  policy_arn = data.aws_iam_policy.ssm_core.arn
}

resource "aws_iam_role_policy_attachment" "compute_cw" {
  role       = aws_iam_role.compute_node.name
  policy_arn = aws_iam_policy.cloudwatch_logs.arn
}

resource "aws_iam_role_policy_attachment" "compute_s3" {
  role       = aws_iam_role.compute_node.name
  policy_arn = aws_iam_policy.s3_access.arn
}

resource "aws_iam_role_policy_attachment" "compute_ecr" {
  role       = aws_iam_role.compute_node.name
  policy_arn = aws_iam_policy.ecr_pull.arn
}

resource "aws_iam_instance_profile" "compute_node" {
  name_prefix = "${var.name_prefix}-compute-"
  role        = aws_iam_role.compute_node.name
}

# ============================================================================
# LOGIN NODE role — SSM only (users SSH in, submit jobs, that's it)
# ============================================================================

resource "aws_iam_role" "login_node" {
  name_prefix        = "${var.name_prefix}-login-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "login_ssm" {
  role       = aws_iam_role.login_node.name
  policy_arn = data.aws_iam_policy.ssm_core.arn
}

resource "aws_iam_role_policy_attachment" "login_cw" {
  role       = aws_iam_role.login_node.name
  policy_arn = aws_iam_policy.cloudwatch_logs.arn
}

# Login node can read/write S3 (some users prefer CLI for uploads)
resource "aws_iam_role_policy_attachment" "login_s3" {
  role       = aws_iam_role.login_node.name
  policy_arn = aws_iam_policy.s3_access.arn
}

resource "aws_iam_instance_profile" "login_node" {
  name_prefix = "${var.name_prefix}-login-"
  role        = aws_iam_role.login_node.name
}

# ============================================================================
# Outputs
# ============================================================================

output "head_node_role_arn" { value = aws_iam_role.head_node.arn }
output "head_node_instance_profile_name" { value = aws_iam_instance_profile.head_node.name }
output "head_node_instance_profile_arn" { value = aws_iam_instance_profile.head_node.arn }

output "compute_node_role_arn" { value = aws_iam_role.compute_node.arn }
output "compute_node_instance_profile_name" { value = aws_iam_instance_profile.compute_node.name }
output "compute_node_instance_profile_arn" { value = aws_iam_instance_profile.compute_node.arn }

output "login_node_role_arn" { value = aws_iam_role.login_node.arn }
output "login_node_instance_profile_name" { value = aws_iam_instance_profile.login_node.name }
