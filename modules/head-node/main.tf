data "aws_ami" "amazon_linux2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_eip" "head_node" {
  domain = "vpc"
  tags   = { Name = "${var.namespace}-${var.env}-head-node-eip" }
}

resource "aws_eip_association" "head_node" {
  instance_id   = aws_instance.head_node.id
  allocation_id = aws_eip.head_node.id
}

resource "aws_instance" "head_node" {
  ami                         = data.aws_ami.amazon_linux2.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  associate_public_ip_address = true
  key_name                    = var.key_name
  iam_instance_profile        = var.iam_instance_profile

  user_data = base64encode(templatefile("${path.module}/scripts/head_node_init.sh.tpl", {
    namespace            = var.namespace
    env                  = var.env
    aws_region           = var.aws_region
    compute_instance_type = var.compute_instance_type
    max_compute_nodes    = var.max_compute_nodes
    launch_template_name = var.launch_template_name
    slurm_db_password    = var.slurm_db_password
    fsx_dns_name         = var.fsx_dns_name
    fsx_mount_name       = var.fsx_mount_name
  }))

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    encrypted   = true
    volume_size = 30
    volume_type = "gp3"
  }

  tags = { Name = "${var.namespace}-${var.env}-head-node" }
}
