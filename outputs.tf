output "login_node_public_ip" {
  value       = module.login_node.public_ip
  description = "Public IP of the login node (entry point for users)"
}

output "login_node_ssh" {
  value       = "ssh -i ~/.ssh/titan-hpc ec2-user@${module.login_node.public_ip}"
  description = "SSH to login node — use this to access the cluster"
}

output "head_node_private_ip" {
  value       = module.head_node.private_ip
  description = "Private IP of the head node (reachable only from login node)"
}

output "compute_asg_name" {
  value       = module.compute_fleet.asg_name
  description = "Name of the compute Auto Scaling Group"
}

output "fsx_dns_name" {
  value       = module.fsx.dns_name
  description = "FSx for Lustre DNS name"
}

output "fsx_cost_warning" {
  value       = "WARNING: FSx SCRATCH_1 (1200 GB) is running. Run 'terraform destroy' after testing to avoid ongoing charges (~$140/month)."
  description = "Cost reminder"
}

output "usage_instructions" {
  value = <<-EOT
    === Cluster Ready ===

    1. SSH to login node (your only entry point):
       ssh -i ~/.ssh/titan-hpc ec2-user@${module.login_node.public_ip}

    2. From login node, submit jobs:
       sbatch ~/job.sh
       squeue
       sinfo
       sacct -a

    3. To reach head node (from login node only):
       ssh ec2-user@${module.head_node.private_ip}

    NOTE: Direct SSH to head node from internet is blocked.

    4. FSx shared filesystem is mounted at /fsx on all nodes:
       /fsx/home/<user>    — home directory (755)
       /fsx/work/<user>    — job output (700, writable by owner only)
       /fsx/shared         — world-writable scratch (777)

    5. Submit FSx test job (as user1 or user2):
       sudo -u user1 sbatch /home/ec2-user/fsx_test_job.sh
  EOT
}
