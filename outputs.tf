output "jobui_url" {
  description = "URL for the web UI. Point your browser here to log in."
  value       = module.alb.https_url
}

output "alb_dns_name" {
  description = "ALB DNS name. Create your CNAME/Alias against this."
  value       = module.alb.dns_name
}

output "login_node_public_ip" {
  description = "Public IP of the login node for SSH access (if enabled)."
  value       = var.enable_login_node ? module.login_node[0].public_ip : null
}

output "head_node_instance_id" {
  description = "Head node EC2 instance ID. Use with 'aws ssm start-session --target <id>' for shell access."
  value       = module.head_node.instance_id
}

output "aurora_writer_endpoint" {
  description = "Aurora cluster writer endpoint (for debugging; reachable only from head/compute nodes)."
  value       = module.aurora.writer_endpoint
  sensitive   = false
}

output "s3_data_bucket" {
  description = "S3 bucket for input uploads and result outputs."
  value       = module.s3.bucket_name
}

output "ecr_registry_url" {
  description = "ECR registry URL. Push model images as <registry>/<repo>:<tag>."
  value       = module.ecr.registry_url
}

output "fsx_dns_name" {
  description = "FSx Lustre DNS name."
  value       = module.fsx.dns_name
}

output "aurora_master_secret_arn" {
  description = "Secrets Manager ARN holding the Aurora master password. Retrieve via: aws secretsmanager get-secret-value --secret-id <arn>"
  value       = module.aurora.master_password_secret_arn
  sensitive   = true
}

output "admin_bootstrap_command" {
  description = "Command to run on the head node (via SSM) to set the initial admin password."
  value       = <<-EOT
    # On head node:
    sudo docker exec jobui-backend python -m app.scripts.bootstrap_admin \
      --email ${var.admin_email} \
      --generate-password
  EOT
}

output "team_config_summary" {
  description = "Summary of what was deployed."
  value = {
    team           = var.team_name
    env            = var.env
    region         = var.aws_region
    primary_az     = var.primary_az
    gpu_families   = var.gpu_families_enabled
    member_count   = length(var.team_members)
    team_budget    = var.team_monthly_budget_usd
  }
}
