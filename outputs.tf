output "login_node_instance_id" {
  description = "Login node EC2 instance ID. Users enter the cluster via: aws ssm start-session --target <id>"
  value       = var.enable_login_node ? module.login_node[0].instance_id : ""
}

output "login_node_public_ip" {
  description = "Public IP of the login node (for SSH access; SSM is preferred)."
  value       = var.enable_login_node ? module.login_node[0].public_ip : ""
}

output "login_node_ssm_command" {
  description = "Ready-to-run command to open a shell on the login node."
  value       = var.enable_login_node ? "aws ssm start-session --region ${var.aws_region} --target ${module.login_node[0].instance_id}" : "(login node disabled)"
}

output "head_node_instance_id" {
  description = "Head node EC2 instance ID. Admin-only. SSM access: aws ssm start-session --target <id>"
  value       = module.head_node.instance_id
}

output "head_node_ssm_command" {
  description = "Admin SSM access to the head node (slurmctld + slurmdbd)."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${module.head_node.instance_id}"
}

output "prometheus_port_forward_command" {
  description = "Admin SSM port-forward to view Prometheus at http://localhost:9090. Cluster + GPU metrics from slurm-exporter and DCGM exporters."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${module.head_node.instance_id} --document-name AWS-StartPortForwardingSession --parameters portNumber=9090,localPortNumber=9090"
}

output "workflow_node_instance_id" {
  description = "Workflow node EC2 instance ID (Snakemake runner)."
  value       = module.workflow_node.instance_id
}

output "workflow_node_ssm_command" {
  description = "Open a shell on the workflow node via SSM."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${module.workflow_node.instance_id}"
}

output "aurora_writer_endpoint" {
  description = "Aurora cluster writer endpoint. Reachable only from head/compute nodes via private subnets."
  value       = module.aurora.writer_endpoint
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
  description = "Secrets Manager ARN for the Aurora master password."
  value       = module.aurora.master_password_secret_arn
  sensitive   = true
}

output "team_config_summary" {
  description = "Summary of what was deployed."
  value = {
    team         = var.team_name
    env          = var.env
    region       = var.aws_region
    primary_az   = var.primary_az
    gpu_families = var.gpu_families_enabled
    team_budget  = var.team_monthly_budget_usd
  }
}
