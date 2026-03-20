# ── Head Node Role ────────────────────────────────────────────────────────────

resource "aws_iam_role" "head_node" {
  name = "${var.namespace}-${var.env}-head-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Name = "${var.namespace}-${var.env}-head-node-role" }
}

resource "aws_iam_role_policy" "head_node" {
  name = "${var.namespace}-${var.env}-head-node-policy"
  role = aws_iam_role.head_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2NodeManagement"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ec2:DescribeInstances",
          "ec2:DescribeTags",
          "ec2:CreateTags",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeImages",
        ]
        Resource = "*"
      },
      {
        Sid    = "AutoScaling"
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:UpdateAutoScalingGroup",
        ]
        Resource = "*"
      },
      {
        Sid    = "SSMParameters"
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:DeleteParameter",
        ]
        Resource = "arn:aws:ssm:*:*:parameter/hpc/${var.namespace}/${var.env}/*"
      },
      {
        Sid      = "PassComputeRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.compute_node.arn
      },
      {
        Sid    = "S3DataPipeline"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${var.s3_bucket_arn}/*"
      },
      {
        Sid      = "S3ListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = var.s3_bucket_arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "head_node" {
  name = "${var.namespace}-${var.env}-head-node-profile"
  role = aws_iam_role.head_node.name
  tags = { Name = "${var.namespace}-${var.env}-head-node-profile" }
}

# ── Compute Node Role ─────────────────────────────────────────────────────────

resource "aws_iam_role" "compute_node" {
  name = "${var.namespace}-${var.env}-compute-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Name = "${var.namespace}-${var.env}-compute-node-role" }
}

resource "aws_iam_role_policy" "compute_node" {
  name = "${var.namespace}-${var.env}-compute-node-policy"
  role = aws_iam_role.compute_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMReadOnly"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:*:*:parameter/hpc/${var.namespace}/${var.env}/*"
      },
      {
        Sid      = "DescribeTags"
        Effect   = "Allow"
        Action   = ["ec2:DescribeTags"]
        Resource = "*"
      },
      {
        Sid    = "S3DataPipeline"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${var.s3_bucket_arn}/*"
      },
      {
        Sid      = "S3ListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = var.s3_bucket_arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "compute_node" {
  name = "${var.namespace}-${var.env}-compute-node-profile"
  role = aws_iam_role.compute_node.name
  tags = { Name = "${var.namespace}-${var.env}-compute-node-profile" }
}

# ── Login Node Role ────────────────────────────────────────────────────────────

resource "aws_iam_role" "login_node" {
  name = "${var.namespace}-${var.env}-login-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Name = "${var.namespace}-${var.env}-login-node-role" }
}

resource "aws_iam_role_policy" "login_node" {
  name = "${var.namespace}-${var.env}-login-node-policy"
  role = aws_iam_role.login_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMReadOnly"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:*:*:parameter/hpc/${var.namespace}/${var.env}/*"
      },
      {
        Sid    = "S3DataPipeline"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${var.s3_bucket_arn}/*"
      },
      {
        Sid      = "S3ListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = var.s3_bucket_arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "login_node" {
  name = "${var.namespace}-${var.env}-login-node-profile"
  role = aws_iam_role.login_node.name
  tags = { Name = "${var.namespace}-${var.env}-login-node-profile" }
}
