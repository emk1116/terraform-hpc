data "aws_ami" "amazon_linux2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_launch_template" "compute" {
  name        = "${var.namespace}-${var.env}-compute-lt"
  description = "Launch template for Slurm compute nodes"
  image_id    = data.aws_ami.amazon_linux2.id
  instance_type = var.instance_type
  key_name    = var.key_name

  iam_instance_profile {
    name = var.iam_instance_profile
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [var.security_group_id]
    subnet_id                   = var.subnet_id
    delete_on_termination       = true
  }

  user_data = base64encode(templatefile("${path.module}/scripts/compute_init.sh.tpl", {
    namespace         = var.namespace
    env               = var.env
    aws_region        = var.aws_region
    max_compute_nodes = var.max_compute_nodes
    fsx_dns_name      = var.fsx_dns_name
    fsx_mount_name    = var.fsx_mount_name
    bucket_name       = var.bucket_name
  }))

  metadata_options {
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Namespace   = var.namespace
      Environment = var.env
      ManagedBy   = "slurm"
      Project     = "hpc"
    }
  }

  tags = {
    Name = "${var.namespace}-${var.env}-compute-lt"
  }
}

resource "aws_autoscaling_group" "compute" {
  name                = "${var.namespace}-${var.env}-compute-asg"
  min_size            = 0
  max_size            = var.max_compute_nodes
  desired_capacity    = 0
  vpc_zone_identifier = [var.subnet_id]

  launch_template {
    id      = aws_launch_template.compute.id
    version = "$Latest"
  }

  # Instances launched by Slurm resume.sh via ec2:RunInstances are NOT tracked
  # by this ASG. The ASG exists for max-cap enforcement and fleet visibility.
  # desired_capacity is managed externally by Slurm resume/suspend scripts.

  tag {
    key                 = "Name"
    value               = "${var.namespace}-${var.env}-compute-asg"
    propagate_at_launch = false
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}
