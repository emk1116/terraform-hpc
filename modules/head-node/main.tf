# ============================================================================
# Head node — Slurm control plane only. Runs slurmctld + slurmdbd.
# Not user-facing. Admins SSM in for maintenance; end users never log in here.
# ============================================================================

variable "name_prefix" { type = string }
variable "team_name" { type = string }
variable "env" { type = string }
variable "aws_region" { type = string }
variable "instance_type" { type = string }
variable "subnet_id" { type = string }
variable "security_group_ids" { type = list(string) }
variable "instance_profile_name" { type = string }

variable "aurora_writer_endpoint" { type = string }
variable "aurora_slurm_secret_arn" { type = string }

variable "s3_bucket_name" { type = string }

variable "fsx_dns_name" { type = string }
variable "fsx_mount_name" { type = string }

variable "gpu_family_spec" { type = any }
variable "gpu_max_nodes" { type = map(number) }
variable "compute_ami_id" { type = string }
variable "launch_template_ids" { type = map(string) }
variable "compute_subnet_ids_by_az" { type = map(string) }
variable "primary_az" { type = string }

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
# Munge key — generated once, stored in SSM. Compute / login / workflow nodes
# fetch the same key on bootstrap to authenticate Slurm RPCs.
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
# Render Slurm configs and Resume/Suspend scripts; upload to S3 so that
# login, workflow, and compute nodes can fetch them on bootstrap.
# ----------------------------------------------------------------------------

locals {
  # Generate Slurm partition lines — one per GPU family.
  # SuspendTime and ResumeTimeout are set per-partition so h100-8x nodes
  # are not terminated after the global 120s default.
  slurm_partitions = join("\n", [
    for family, spec in var.gpu_family_spec :
    format(
      "PartitionName=%s Nodes=%s-[1-%d] MaxTime=24:00:00 State=UP SuspendTime=%d ResumeTimeout=%d",
      spec.partition,
      family,
      lookup(var.gpu_max_nodes, family, 2),
      spec.suspend_time_s,
      spec.resume_timeout_s,
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
# Head node user_data — installs Slurm controller, starts slurmctld + slurmdbd
# ----------------------------------------------------------------------------

locals {
  user_data = templatefile("${path.module}/templates/head-user-data.sh.tpl", {
    team_name      = var.team_name
    env            = var.env
    aws_region     = var.aws_region
    s3_bucket      = var.s3_bucket_name
    fsx_dns_name   = var.fsx_dns_name
    fsx_mount_name = var.fsx_mount_name

    aurora_endpoint         = var.aurora_writer_endpoint
    aurora_slurm_secret_arn = var.aurora_slurm_secret_arn

    munge_key_parameter = aws_ssm_parameter.munge_key.name
  })
}

resource "aws_instance" "head" {
  ami           = data.aws_ami.al2023.id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id

  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = var.instance_profile_name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = local.user_data

  tags = {
    Name = "${var.name_prefix}-head"
    Role = "head"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

output "instance_id" { value = aws_instance.head.id }
output "private_ip" { value = aws_instance.head.private_ip }
