# ============================================================================
# Titan HPC — GPU Inference Platform
# Root module. Invoke once per team.
# ============================================================================

locals {
  name_prefix = "${var.team_name}-${var.env}"

  # Centralized map of GPU family → EC2 instance config.
  # Used by compute-fleet to build launch templates and by head-node/slurm to
  # generate partition/node definitions. Change here once, propagates everywhere.
  gpu_family_spec = {
    t4 = {
      instance_type    = "g4dn.xlarge"
      gpus_per_node    = 1
      gpu_memory_gb    = 16
      cpus_per_node    = 4
      memory_mb        = 15000
      ebs_size_gb      = 100
      partition        = "gpu-t4"
      hourly_cost_usd  = 0.526
      resume_timeout_s = 600
      suspend_time_s   = 120
      uses_nvme_local  = false
    }
    a10g = {
      instance_type    = "g5.xlarge"
      gpus_per_node    = 1
      gpu_memory_gb    = 24
      cpus_per_node    = 4
      memory_mb        = 15000
      ebs_size_gb      = 100
      partition        = "gpu-a10g"
      hourly_cost_usd  = 1.006
      resume_timeout_s = 600
      suspend_time_s   = 120
      uses_nvme_local  = false
    }
    l4 = {
      instance_type    = "g6.xlarge"
      gpus_per_node    = 1
      gpu_memory_gb    = 24
      cpus_per_node    = 4
      memory_mb        = 15000
      ebs_size_gb      = 100
      partition        = "gpu-l4"
      hourly_cost_usd  = 0.805
      resume_timeout_s = 600
      suspend_time_s   = 120
      uses_nvme_local  = false
    }
    a100 = {
      instance_type    = "p4d.24xlarge"
      gpus_per_node    = 8
      gpu_memory_gb    = 40
      cpus_per_node    = 96
      memory_mb        = 1100000
      ebs_size_gb      = 200
      partition        = "gpu-a100"
      hourly_cost_usd  = 32.77
      resume_timeout_s = 900
      suspend_time_s   = 600
      uses_nvme_local  = true
    }
    h100-1x = {
      instance_type    = "p5.4xlarge"
      gpus_per_node    = 1
      gpu_memory_gb    = 80
      cpus_per_node    = 16
      memory_mb        = 245000
      ebs_size_gb      = 200
      partition        = "gpu-h100-1x"
      hourly_cost_usd  = 6.88
      resume_timeout_s = 1200
      suspend_time_s   = 600
      uses_nvme_local  = true
    }
    h100-8x = {
      instance_type    = "p5.48xlarge"
      gpus_per_node    = 8
      gpu_memory_gb    = 80
      cpus_per_node    = 192
      memory_mb        = 2000000
      ebs_size_gb      = 500
      partition        = "gpu-h100-8x"
      hourly_cost_usd  = 55.04
      resume_timeout_s = 1800
      suspend_time_s   = 900
      uses_nvme_local  = true
    }
  }

  # Filter by what the user actually enabled
  active_gpus = {
    for family, spec in local.gpu_family_spec :
    family => spec
    if contains(var.gpu_families_enabled, family)
  }
}

# ----------------------------------------------------------------------------
# Network — VPC, subnets, NAT, VPC endpoints, security groups
# ----------------------------------------------------------------------------

module "network" {
  source = "./modules/network"

  name_prefix       = local.name_prefix
  vpc_cidr          = var.vpc_cidr
  primary_az        = var.primary_az
  aws_region        = var.aws_region
  h100_fallback_azs = var.h100_fallback_azs
  ssh_allowed_cidr  = var.ssh_allowed_cidr
  alb_allowed_cidrs = var.alb_allowed_cidrs
}

# ----------------------------------------------------------------------------
# S3 data bucket — input uploads, results, model weights (DRA source)
# ----------------------------------------------------------------------------

module "s3" {
  source = "./modules/s3"

  name_prefix   = local.name_prefix
  team_name     = var.team_name
  force_destroy = var.s3_bucket_force_destroy
}

# ----------------------------------------------------------------------------
# ECR — per-team repositories for model container images
# ----------------------------------------------------------------------------

module "ecr" {
  source = "./modules/ecr"

  name_prefix = local.name_prefix
  team_name   = var.team_name

  # Initial repos; admins can push more later via standard aws ecr CLI
  initial_repos = [
    "models/generic",
    "models/evo2",
    "models/esmfold",
  ]
}

# ----------------------------------------------------------------------------
# IAM — roles and instance profiles for every node class
# ----------------------------------------------------------------------------

module "iam" {
  source = "./modules/iam"

  name_prefix     = local.name_prefix
  team_name       = var.team_name
  aws_region      = var.aws_region
  s3_bucket_arn   = module.s3.bucket_arn
  ecr_repo_arns   = module.ecr.repository_arns
  secrets_arns    = [] # Populated after aurora module creates them
  aurora_resource_id = null  # Set after aurora module
}

# ----------------------------------------------------------------------------
# Aurora Serverless v2 MySQL — slurm_acct_db + jobui databases
# ----------------------------------------------------------------------------

module "aurora" {
  source = "./modules/aurora"

  name_prefix              = local.name_prefix
  team_name                = var.team_name
  vpc_id                   = module.network.vpc_id
  db_subnet_ids            = module.network.private_subnet_ids
  primary_az               = var.primary_az
  allowed_sg_ids           = [module.network.head_node_sg_id, module.network.compute_sg_id]
  min_capacity_acu         = var.aurora_min_capacity_acu
  max_capacity_acu         = var.aurora_max_capacity_acu
  backup_retention_days    = var.aurora_backup_retention_days
}

# ----------------------------------------------------------------------------
# Valkey Serverless — ElastiCache for sessions, rate limiting, queue cache
# ----------------------------------------------------------------------------

module "valkey" {
  source = "./modules/valkey"

  name_prefix    = local.name_prefix
  vpc_id         = module.network.vpc_id
  subnet_ids     = module.network.private_subnet_ids
  allowed_sg_ids = [module.network.head_node_sg_id]
}

# ----------------------------------------------------------------------------
# FSx Lustre — shared filesystem for models and per-job scratch
# ----------------------------------------------------------------------------

module "fsx" {
  source = "./modules/fsx"

  name_prefix          = local.name_prefix
  subnet_id            = module.network.private_subnet_ids[0] # Single AZ
  security_group_ids   = [module.network.fsx_sg_id]
  storage_capacity_gib = var.fsx_storage_capacity_gib
  s3_bucket_name       = module.s3.bucket_name
}

# ----------------------------------------------------------------------------
# ALB — public entry point for the web UI
# ----------------------------------------------------------------------------

module "alb" {
  source = "./modules/alb"

  name_prefix         = local.name_prefix
  vpc_id              = module.network.vpc_id
  public_subnet_ids   = module.network.public_subnet_ids
  alb_sg_id           = module.network.alb_sg_id
  acm_certificate_arn = var.acm_certificate_arn
}

# ----------------------------------------------------------------------------
# Head node — Slurm controller + FastAPI + React UI + slurmdbd
# ----------------------------------------------------------------------------

module "head_node" {
  source = "./modules/head-node"

  name_prefix           = local.name_prefix
  team_name             = var.team_name
  env                   = var.env
  aws_region            = var.aws_region
  instance_type         = var.head_node_instance_type
  subnet_id             = module.network.private_subnet_ids[0]
  security_group_ids    = [module.network.head_node_sg_id]
  instance_profile_name = module.iam.head_node_instance_profile_name
  target_group_arn      = module.alb.jobui_target_group_arn

  # Aurora connection
  aurora_writer_endpoint   = module.aurora.writer_endpoint
  aurora_reader_endpoint   = module.aurora.reader_endpoint
  aurora_slurm_secret_arn  = module.aurora.slurm_db_password_secret_arn
  aurora_jobui_secret_arn  = module.aurora.jobui_db_password_secret_arn

  # Valkey connection
  valkey_endpoint = module.valkey.endpoint

  # S3 and ECR
  s3_bucket_name     = module.s3.bucket_name
  ecr_registry_url   = module.ecr.registry_url

  # FSx
  fsx_dns_name     = module.fsx.dns_name
  fsx_mount_name   = module.fsx.mount_name

  # Slurm / compute fleet config (passed through to resume-node.sh and slurm.conf)
  gpu_family_spec  = local.active_gpus
  gpu_max_nodes    = var.gpu_max_nodes
  compute_ami_id   = module.compute_fleet.ami_id
  launch_template_ids = module.compute_fleet.launch_template_ids
  compute_subnet_ids_by_az = module.network.compute_subnet_ids_by_az
  primary_az       = var.primary_az

  # Team config (seeded into jobui DB on first boot)
  team_members                  = var.team_members
  admin_email                   = var.admin_email
  jwt_expiry_hours              = var.jwt_expiry_hours
  default_user_monthly_budget   = var.default_user_monthly_budget_usd

  depends_on = [module.aurora, module.valkey, module.fsx]
}

# ----------------------------------------------------------------------------
# Login node — optional SSH entry point
# ----------------------------------------------------------------------------

module "login_node" {
  count  = var.enable_login_node ? 1 : 0
  source = "./modules/login-node"

  name_prefix           = local.name_prefix
  instance_type         = var.login_node_instance_type
  subnet_id             = module.network.public_subnet_ids[0]
  security_group_ids    = [module.network.login_node_sg_id]
  instance_profile_name = module.iam.login_node_instance_profile_name
  ssh_public_key        = file("${pathexpand("~/.ssh/titan-hpc.pub")}")

  # Needs to know FSx and head node to mount/submit
  fsx_dns_name   = module.fsx.dns_name
  fsx_mount_name = module.fsx.mount_name
  head_node_ip   = module.head_node.private_ip
}

# ----------------------------------------------------------------------------
# Compute fleet — launch templates per GPU family
# ----------------------------------------------------------------------------

module "compute_fleet" {
  source = "./modules/compute-fleet"

  name_prefix           = local.name_prefix
  team_name             = var.team_name
  active_gpus           = local.active_gpus
  instance_profile_name = module.iam.compute_node_instance_profile_name
  security_group_ids    = [module.network.compute_sg_id]
  subnet_id             = module.network.private_subnet_ids[0]

  fsx_dns_name     = module.fsx.dns_name
  fsx_mount_name   = module.fsx.mount_name
  head_node_ip     = module.head_node.private_ip
  ecr_registry_url = module.ecr.registry_url
  s3_bucket_name   = module.s3.bucket_name
}

# ----------------------------------------------------------------------------
# Budgets — AWS Budgets alarm for team spend
# ----------------------------------------------------------------------------

resource "aws_budgets_budget" "team_monthly" {
  name         = "${local.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = var.team_monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Team$${var.team_name}"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.admin_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.admin_email]
  }
}
