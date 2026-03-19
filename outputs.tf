output "head_node_public_ip" {
  value       = module.head_node.public_ip
  description = "Public IP of the head node"
}

output "head_node_ssh" {
  value       = "ssh -i ~/.ssh/titan-hpc ec2-user@${module.head_node.public_ip}"
  description = "SSH command for the head node"
}

output "compute_asg_name" {
  value       = module.compute_fleet.asg_name
  description = "Name of the compute Auto Scaling Group"
}

output "usage_instructions" {
  value = <<-EOT
    === Cluster Ready ===
    SSH:     ssh -i ~/.ssh/titan-hpc ec2-user@${module.head_node.public_ip}

    Commands (run on head node):
      sinfo                   - show node/partition status
      squeue                  - show job queue
      sbatch jobs/job.sh      - submit the sample job array
      sacct -a                - show accounting data
      scontrol show nodes     - detailed node info
  EOT
}
