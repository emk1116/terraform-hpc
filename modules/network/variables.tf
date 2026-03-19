variable "vpc_cidr" {}
variable "namespace" {}
variable "env" {}
variable "ssh_allowed_cidr" {
  description = "CIDR allowed to SSH into the head node"
}
