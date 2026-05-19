output "jobui_url" {
  description = "URL for the web UI when ALB is enabled. Empty when running ALB-less + local podman UI."
  value       = var.enable_alb ? module.alb[0].https_url : ""
}

output "alb_dns_name" {
  description = "ALB DNS name when enabled."
  value       = var.enable_alb ? module.alb[0].dns_name : ""
}

output "ssm_port_forward_command" {
  description = "When ALB is disabled, run this on your laptop to expose the head node API at localhost:8080, then start the local podman UI."
  value       = var.enable_alb ? "" : "aws ssm start-session --region ${var.aws_region} --target ${module.head_node.instance_id} --document-name AWS-StartPortForwardingSession --parameters portNumber=80,localPortNumber=8080"
}

output "login_node_public_ip" {
  description = "Public IP of the login node for SSH access (if enabled)."
  value       = var.enable_login_node ? module.login_node[0].public_ip : null
}

output "head_node_instance_id" {
  description = "Head node EC2 instance ID. Use with 'aws ssm start-session --target <id>' for shell access."
  value       = module.head_node.instance_id
}

output "workflow_node_instance_id" {
  description = "Workflow node EC2 instance ID (Snakemake/Nextflow runner). Empty when disabled."
  value       = var.enable_workflow_node ? module.workflow_node[0].instance_id : ""
}

output "workflow_node_ssm_command" {
  description = "Open a shell on the workflow node via SSM."
  value       = var.enable_workflow_node ? "aws ssm start-session --region ${var.aws_region} --target ${module.workflow_node[0].instance_id}" : ""
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

output "admin_temp_password_command" {
  description = "Command to retrieve the auto-generated admin temp password from Secrets Manager."
  value       = "aws secretsmanager get-secret-value --region ${var.aws_region} --secret-id ${module.head_node.admin_temp_password_secret_arn} --query SecretString --output text"
}

output "team_config_summary" {
  description = "Summary of what was deployed."
  value = {
    team         = var.team_name
    env          = var.env
    region       = var.aws_region
    primary_az   = var.primary_az
    gpu_families = var.gpu_families_enabled
    member_count = length(var.team_members)
    team_budget  = var.team_monthly_budget_usd
  }
}
