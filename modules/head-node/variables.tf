variable "namespace" {}
variable "env" {}
variable "instance_type" {}
variable "subnet_id" {}
variable "security_group_id" {}
variable "iam_instance_profile" {}
variable "key_name" {}
variable "aws_region" {}
variable "compute_instance_type" {}
variable "max_compute_nodes" {}
variable "launch_template_name" {}
variable "slurm_db_password" {
  sensitive = true
}
variable "fsx_dns_name" {}
variable "fsx_mount_name" {}
variable "bucket_name" {}
