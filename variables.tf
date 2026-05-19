# ============================================================================
# Core identity — what team is this cluster for, what environment
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

variable "alb_allowed_cidrs" {
  description = "CIDR blocks allowed to reach the ALB (web UI). Default is open to the internet; tighten for prod."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "acm_certificate_arn" {
  description = "ARN of an ACM certificate in the same region for the ALB HTTPS listener. Required only when enable_alb=true."
  type        = string
  default     = ""
}

variable "enable_alb" {
  description = "Whether to deploy the public ALB. Set false to use SSM port-forwarding from a local podman UI to the head node (saves ~$0.55/day and avoids the ACM cert requirement)."
  type        = bool
  default     = false
}

variable "head_node_http_cidrs" {
  description = "CIDRs allowed to reach the head node API on port 80 directly. Default empty = SSM port-forward only. Add your own /32 if you want direct public access."
  type        = list(string)
  default     = []
}

variable "cors_allowed_origins" {
  description = "Comma-separated list of origins the backend will accept CORS requests from. For local podman UI use 'http://localhost:3000'. Default '*' allows any origin (no credentials)."
  type        = string
  default     = "*"
}

variable "enable_login_node" {
  description = "Deploy the SSH login node in a public subnet. Set false if you'll only use SSM Session Manager."
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
# Database
# ============================================================================

variable "aurora_min_capacity_acu" {
  description = "Aurora Serverless v2 minimum ACU. 0.5 is the floor."
  type        = number
  default     = 0.5
}

variable "aurora_max_capacity_acu" {
  description = "Aurora Serverless v2 maximum ACU. 4 is plenty for one team with 20 concurrent jobs."
  type        = number
  default     = 4
}

variable "aurora_backup_retention_days" {
  description = "Aurora automated backup retention."
  type        = number
  default     = 7
}

# ============================================================================
# Users — the team members who get accounts in jobui
# ============================================================================

variable "admin_email" {
  description = "Email of the initial admin user. They'll receive a temp password via terraform output."
  type        = string
}

variable "team_members" {
  description = <<-EOT
    List of team members to pre-provision in the jobui database. Each member becomes an app_users row.
    Admins can add more later via the UI. H100-approved members can use the H100 partitions.

    Example:
      team_members = [
        {
          username          = "alice"
          email             = "alice@example.com"
          display_name      = "Alice Example"
          role              = "admin"
          h100_approved     = true
          monthly_budget_usd = 2000
        },
        {
          username          = "bob"
          email             = "bob@example.com"
          display_name      = "Bob Example"
          role              = "member"
          h100_approved     = false
          monthly_budget_usd = 500
        },
      ]
  EOT
  type = list(object({
    username           = string
    email              = string
    display_name       = string
    role               = string
    h100_approved      = bool
    monthly_budget_usd = number
  }))
  default = []
}

# ============================================================================
# Head / login node sizing
# ============================================================================

variable "head_node_instance_type" {
  description = "Head node size. t3.medium handles 20 concurrent jobs; bump to t3.large for more."
  type        = string
  default     = "t3.medium"
}

variable "login_node_instance_type" {
  description = "Login node size. t3.small is plenty for SSH + job submission."
  type        = string
  default     = "t3.small"
}

variable "enable_workflow_node" {
  description = "Deploy a separate workflow node for Snakemake/Nextflow. t3.small adds ~$0.50/day. Set false to run workflows on the login node instead."
  type        = bool
  default     = true
}

variable "workflow_node_instance_type" {
  description = "Workflow node size. t3.small handles Snakemake DAGs comfortably."
  type        = string
  default     = "t3.small"
}

# ============================================================================
# jobui configuration
# ============================================================================

variable "jobui_image_tag" {
  description = "Docker image tag for the jobui backend + frontend. 'latest' for dev, pinned SHA for prod."
  type        = string
  default     = "latest"
}

variable "jwt_expiry_hours" {
  description = "JWT token lifetime in hours."
  type        = number
  default     = 8
}

# ============================================================================
# Cost guardrails
# ============================================================================

variable "team_monthly_budget_usd" {
  description = "Soft budget alarm for the whole team. AWS Budgets sends an email when crossed."
  type        = number
  default     = 5000
}

variable "default_user_monthly_budget_usd" {
  description = "Default monthly GPU spend budget per new user created via the UI."
  type        = number
  default     = 500
}
