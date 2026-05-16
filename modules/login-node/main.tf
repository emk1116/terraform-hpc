variable "name_prefix" { type = string }
variable "instance_type" { type = string }
variable "subnet_id" { type = string }
variable "security_group_ids" { type = list(string) }
variable "instance_profile_name" { type = string }
variable "ssh_public_key" { type = string }
variable "fsx_dns_name" { type = string }
variable "fsx_mount_name" { type = string }
variable "head_node_ip" { type = string }

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_key_pair" "login" {
  key_name_prefix = "${var.name_prefix}-"
  public_key      = var.ssh_public_key
}

resource "aws_eip" "login" {
  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-login-eip" }
}

resource "aws_instance" "login" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  key_name               = aws_key_pair.login.key_name
  iam_instance_profile   = var.instance_profile_name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user-data.sh.tpl", {
    fsx_dns_name   = var.fsx_dns_name
    fsx_mount_name = var.fsx_mount_name
    head_node_ip   = var.head_node_ip
  })

  tags = {
    Name = "${var.name_prefix}-login"
    Role = "login"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_eip_association" "login" {
  instance_id   = aws_instance.login.id
  allocation_id = aws_eip.login.id
}

output "instance_id" { value = aws_instance.login.id }
output "public_ip" { value = aws_eip.login.public_ip }
