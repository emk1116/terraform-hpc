# ============================================================================
# Core identity
# ============================================================================

variable "team_name" {
  description = "Team identifier — used as prefix for all AWS resources. Must be lowercase alphanumeric with hyphens, 3-20 chars."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,19}$", var.team_name))
    error_message = "team_name must be 3-20 chars, lowercase alphanumeric + hyphens, starting with a letter."
  }
}

variable "env" {
  description = "Environment name (non-prod, staging, prod)."
  type        = string
  default     = "non-prod"
}

variable "aws_region" {
  description = "AWS region. Changing this requires destroy + recreate."
  type        = string
  default     = "us-east-1"
}

variable "primary_az" {
  description = "Single AZ for Aurora, FSx, and compute placement. us-east-1f is cheap but has tighter H100 capacity than us-east-1a."
  type        = string
  default     = "us-east-1f"
}

# ============================================================================
# Network
# ============================================================================

variable "vpc_cidr" {
  description = "CIDR block for the team VPC. /16 recommended; pick a non-overlapping range per team."
  type        = string
  default     = "10.20.0.0/16"
}

variable "ssh_allowed_cidr" {
  description = "CIDR allowed to SSH to the login node. Your public IP in /32 form. Use 'curl ifconfig.me' to find yours."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.ssh_allowed_cidr))
    error_message = "ssh_allowed_cidr must be a valid CIDR (e.g. 203.0.113.5/32)."
  }
}

variable "enable_login_node" {
  description = "Deploy the SSH/SSM login node. Strongly recommended — it's the user's entry point. Set false only if you'll SSM into the head node directly (admin-only)."
  type        = bool
  default     = true
}

# ============================================================================
# Compute / GPU
# ============================================================================

variable "gpu_families_enabled" {
  description = "Which GPU families to provision launch templates and partitions for. Omit H100 here if you don't have quota yet."
  type        = list(string)
  default     = ["t4", "a10g", "l4", "a100", "h100-1x"]

  validation {
    condition = alltrue([
      for f in var.gpu_families_enabled :
      contains(["t4", "a10g", "l4", "a100", "h100-1x", "h100-8x"], f)
    ])
    error_message = "Valid gpu families: t4, a10g, l4, a100, h100-1x, h100-8x."
  }
}

variable "gpu_max_nodes" {
  description = "Max concurrent compute nodes per GPU family. Must be ≤ your AWS quota."
  type        = map(number)
  default = {
    t4      = 10
    a10g    = 20
    l4      = 15
    a100    = 2
    h100-1x = 4
    h100-8x = 1
  }
}

variable "h100_fallback_azs" {
  description = "Additional AZs to try when launching H100 instances on InsufficientInstanceCapacity. Only used if FSx is in primary_az and you accept cross-AZ traffic cost for capacity."
  type        = list(string)
  default     = []
}

# ============================================================================
# Storage
# ============================================================================

variable "fsx_storage_capacity_gib" {
  description = "FSx Lustre capacity. SCRATCH_2 throughput scales with size: 2400 GiB = 480 MB/s."
  type        = number
  default     = 2400
}

variable "s3_bucket_force_destroy" {
  description = "Allow terraform destroy to nuke the S3 data bucket with objects in it. True for non-prod, false for prod."
  type        = bool
  default     = true
}

# ============================================================================
# Database (slurmdbd accounting only)
# ============================================================================

variable "aurora_min_capacity_acu" {
  description = "Aurora Serverless v2 minimum ACU. 0.5 is the floor."
  type        = number
  default     = 0.5
}

variable "aurora_max_capacity_acu" {
  description = "Aurora Serverless v2 maximum ACU. 4 is plenty for slurmdbd."
  type        = number
  default     = 4
}

variable "aurora_backup_retention_days" {
  description = "Aurora automated backup retention."
  type        = number
  default     = 7
}

# ============================================================================
# Head / login / workflow node sizing
# ============================================================================

variable "head_node_instance_type" {
  description = "Head node size. t3.small handles slurmctld + slurmdbd comfortably; bump if you have many compute nodes."
  type        = string
  default     = "t3.small"
}

variable "login_node_instance_type" {
  description = "Login node size. t3.small is plenty for SSH + sbatch + light interactive work."
  type        = string
  default     = "t3.small"
}

variable "workflow_node_instance_type" {
  description = "Workflow node size. Always deployed; t3.small handles Snakemake DAGs comfortably."
  type        = string
  default     = "t3.small"
}

# ============================================================================
# Cost guardrails — AWS Budgets only sends email alerts; doesn't enforce
# ============================================================================

variable "admin_email" {
  description = "Email of the cluster admin. Receives AWS Budgets alerts."
  type        = string
}

variable "team_monthly_budget_usd" {
  description = "Soft budget alarm for the whole team. AWS Budgets sends email when crossed."
  type        = number
  default     = 100
}
