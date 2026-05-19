variable "name_prefix" { type = string }
variable "team_name" { type = string }
variable "env" { type = string }
variable "aws_region" { type = string }
variable "instance_type" { type = string }
variable "subnet_id" { type = string }
variable "security_group_ids" { type = list(string) }
variable "instance_profile_name" { type = string }
variable "target_group_arn" {
  description = "ALB target group ARN. Empty string means ALB is disabled — skip target group attachment."
  type        = string
  default     = ""
}

variable "cors_allowed_origins" {
  description = "CORS origins passed to the backend (comma-separated)."
  type        = string
  default     = "*"
}

variable "aurora_writer_endpoint" { type = string }
variable "aurora_reader_endpoint" { type = string }
variable "aurora_slurm_secret_arn" { type = string }
variable "aurora_jobui_secret_arn" { type = string }

variable "valkey_endpoint" { type = string }

variable "s3_bucket_name" { type = string }
variable "ecr_registry_url" { type = string }

variable "fsx_dns_name" { type = string }
variable "fsx_mount_name" { type = string }

variable "gpu_family_spec" { type = any }
variable "gpu_max_nodes" { type = map(number) }
variable "compute_ami_id" { type = string }
variable "launch_template_ids" { type = map(string) }
variable "compute_subnet_ids_by_az" { type = map(string) }
variable "primary_az" { type = string }

variable "team_members" {
  type = list(object({
    username           = string
    email              = string
    display_name       = string
    role               = string
    h100_approved      = bool
    monthly_budget_usd = number
  }))
}
variable "admin_email" { type = string }
variable "jwt_expiry_hours" { type = number }
variable "default_user_monthly_budget" { type = number }

# ----------------------------------------------------------------------------
# AMI — Amazon Linux 2023 on head node (doesn't need GPU drivers)
# ----------------------------------------------------------------------------

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# ----------------------------------------------------------------------------
# Munge key — generated once, stored in SSM, compute nodes fetch it
# ----------------------------------------------------------------------------

resource "random_bytes" "munge" {
  length = 1024
}

resource "aws_ssm_parameter" "munge_key" {
  name  = "/titan-hpc/${var.team_name}/munge-key"
  type  = "SecureString"
  value = random_bytes.munge.base64

  tags = { Name = "${var.name_prefix}-munge-key" }
}

# ----------------------------------------------------------------------------
# JWT secret for jobui
# ----------------------------------------------------------------------------

resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "jwt" {
  name_prefix             = "${var.name_prefix}-jobui-jwt-"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "jwt" {
  secret_id     = aws_secretsmanager_secret.jwt.id
  secret_string = random_password.jwt_secret.result
}

# Initial admin temp password (bootstrap — user changes on first login)
resource "random_password" "admin_temp" {
  length           = 16
  special          = true
  override_special = "!@#$%^&*-_=+"
}

resource "aws_secretsmanager_secret" "admin_temp" {
  name_prefix             = "${var.name_prefix}-admin-temp-"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "admin_temp" {
  secret_id     = aws_secretsmanager_secret.admin_temp.id
  secret_string = random_password.admin_temp.result
}

# ----------------------------------------------------------------------------
# Drop Slurm configs + helper scripts into S3 so compute nodes can fetch them.
# We generate slurm.conf and gres.conf here with the correct partitions.
# ----------------------------------------------------------------------------

locals {
  # Generate Slurm partition lines — one per GPU family.
  # SuspendTime and ResumeTimeout are set per-partition so h100-8x nodes
  # are not terminated after the global 120s default.
  slurm_partitions = join("\n", [
    for family, spec in var.gpu_family_spec :
    format(
      "PartitionName=%s Nodes=%s-[1-%d] MaxTime=24:00:00 State=UP SuspendTime=%d ResumeTimeout=%d%s",
      spec.partition,
      family,
      lookup(var.gpu_max_nodes, family, 2),
      spec.suspend_time_s,
      spec.resume_timeout_s,
      startswith(family, "h100") ? " AllowAccounts=h100-approved" : ""
    )
  ])

  slurm_nodes = join("\n", [
    for family, spec in var.gpu_family_spec :
    format(
      "NodeName=%s-[1-%d] CPUs=%d RealMemory=%d Gres=gpu:%s:%d State=CLOUD",
      family,
      lookup(var.gpu_max_nodes, family, 2),
      spec.cpus_per_node,
      spec.memory_mb,
      family,
      spec.gpus_per_node
    )
  ])

  # Build AccountingStorageTRES from the actual GPU family names so they match
  # the NodeName Gres= definitions (e.g. "gpu:h100-1x", not "gpu:h100").
  gres_tres = join(",", concat(
    ["gres/gpu"],
    [for family, _ in var.gpu_family_spec : "gres/gpu:${family}"]
  ))

  slurm_conf = templatefile("${path.module}/templates/slurm.conf.tpl", {
    cluster_name     = "titan-${var.team_name}"
    control_machine  = "head"
    slurm_partitions = local.slurm_partitions
    slurm_nodes      = local.slurm_nodes
    gres_tres        = local.gres_tres
    aurora_endpoint  = var.aurora_writer_endpoint
  })

  slurmdbd_conf = templatefile("${path.module}/templates/slurmdbd.conf.tpl", {
    aurora_endpoint  = var.aurora_writer_endpoint
    slurm_secret_arn = var.aurora_slurm_secret_arn
    aws_region       = var.aws_region
  })

  gres_conf = "AutoDetect=nvml\n"

  # resume-node.sh generated from template
  resume_script = templatefile("${path.module}/templates/resume-node.sh.tpl", {
    team_name                = var.team_name
    aws_region               = var.aws_region
    primary_subnet_id        = var.compute_subnet_ids_by_az[var.primary_az]
    compute_subnet_ids_by_az = jsonencode(var.compute_subnet_ids_by_az)
    launch_template_ids      = jsonencode(var.launch_template_ids)
    gpu_family_instance_types = jsonencode({
      for family, spec in var.gpu_family_spec : family => spec.instance_type
    })
  })

  suspend_script = templatefile("${path.module}/templates/suspend-node.sh.tpl", {
    aws_region = var.aws_region
    team_name  = var.team_name
  })
}

# Upload config artifacts to S3 — compute nodes will fetch these on boot
resource "aws_s3_object" "slurm_conf" {
  bucket  = var.s3_bucket_name
  key     = "platform/slurm.conf"
  content = local.slurm_conf
  etag    = md5(local.slurm_conf)
}

resource "aws_s3_object" "gres_conf" {
  bucket  = var.s3_bucket_name
  key     = "platform/gres.conf"
  content = local.gres_conf
  etag    = md5(local.gres_conf)
}

resource "aws_s3_object" "slurmdbd_conf_tpl" {
  bucket  = var.s3_bucket_name
  key     = "platform/slurmdbd.conf.tpl"
  content = local.slurmdbd_conf
  etag    = md5(local.slurmdbd_conf)
}

resource "aws_s3_object" "resume_script" {
  bucket  = var.s3_bucket_name
  key     = "platform/resume-node.sh"
  content = local.resume_script
  etag    = md5(local.resume_script)
}

resource "aws_s3_object" "suspend_script" {
  bucket  = var.s3_bucket_name
  key     = "platform/suspend-node.sh"
  content = local.suspend_script
  etag    = md5(local.suspend_script)
}

# ----------------------------------------------------------------------------
# Initial admin + team members seed — rendered to JSON and picked up by jobui
# backend on first start to populate the app_users table
# ----------------------------------------------------------------------------

locals {
  users_seed = jsonencode({
    admin = {
      email         = var.admin_email
      temp_password = random_password.admin_temp.result
    }
    members = var.team_members
  })
}

resource "aws_ssm_parameter" "users_seed" {
  name  = "/titan-hpc/${var.team_name}/users-seed"
  type  = "SecureString"
  value = local.users_seed

  tags = { Name = "${var.name_prefix}-users-seed" }
}

# ----------------------------------------------------------------------------
# Head node instance user data — installs everything, pulls configs,
# starts jobui stack in Docker Compose.
# ----------------------------------------------------------------------------

locals {
  user_data = templatefile("${path.module}/templates/head-user-data.sh.tpl", {
    team_name      = var.team_name
    env            = var.env
    aws_region     = var.aws_region
    s3_bucket      = var.s3_bucket_name
    ecr_registry   = var.ecr_registry_url
    fsx_dns_name   = var.fsx_dns_name
    fsx_mount_name = var.fsx_mount_name

    aurora_endpoint          = var.aurora_writer_endpoint
    aurora_reader_endpoint   = var.aurora_reader_endpoint
    aurora_master_secret_arn = "" # master password not needed on head
    aurora_slurm_secret_arn  = var.aurora_slurm_secret_arn
    aurora_jobui_secret_arn  = var.aurora_jobui_secret_arn

    valkey_endpoint = var.valkey_endpoint

    jwt_secret_arn        = aws_secretsmanager_secret.jwt.arn
    admin_temp_secret_arn = aws_secretsmanager_secret.admin_temp.arn
    users_seed_parameter  = aws_ssm_parameter.users_seed.name
    munge_key_parameter   = aws_ssm_parameter.munge_key.name

    admin_email          = var.admin_email
    jwt_expiry_hours     = var.jwt_expiry_hours
    default_user_budget  = var.default_user_monthly_budget
    cors_allowed_origins = var.cors_allowed_origins

    gpu_family_spec_json = jsonencode(var.gpu_family_spec)
  })
}

# ----------------------------------------------------------------------------
# Head node EC2 instance
# ----------------------------------------------------------------------------

resource "aws_instance" "head" {
  ami           = data.aws_ami.al2023.id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id

  vpc_security_group_ids = var.security_group_ids

  iam_instance_profile = var.instance_profile_name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = local.user_data

  tags = {
    Name = "${var.name_prefix}-head"
    Role = "head"
  }

  # ASG not needed — single instance; recreate on config changes
  lifecycle {
    ignore_changes = [ami]
  }
}

# ----------------------------------------------------------------------------
# Register with ALB target group
# ----------------------------------------------------------------------------

resource "aws_lb_target_group_attachment" "head" {
  count            = var.target_group_arn != "" ? 1 : 0
  target_group_arn = var.target_group_arn
  target_id        = aws_instance.head.id
  port             = 80
}

# ----------------------------------------------------------------------------
# Outputs
# ----------------------------------------------------------------------------

output "instance_id" { value = aws_instance.head.id }
output "private_ip" { value = aws_instance.head.private_ip }
output "admin_temp_password_secret_arn" { value = aws_secretsmanager_secret.admin_temp.arn }
output "jwt_secret_arn" { value = aws_secretsmanager_secret.jwt.arn }
