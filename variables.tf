variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "head_node_instance_type" {
  type    = string
  default = "t3.small"
}

variable "compute_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "namespace" {
  type = string
}

variable "env" {
  type = string
}

variable "ssh_allowed_cidr" {
  type        = string
  description = "CIDR allowed to SSH into the head node"
}

variable "public_key_path" {
  type        = string
  description = "Path to SSH public key"
  default     = "~/.ssh/titan-hpc.pub"
}

variable "max_compute_nodes" {
  type    = number
  default = 10
}
