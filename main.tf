resource "random_password" "slurm_db" {
  length  = 24
  special = false
}

resource "aws_key_pair" "hpc_key" {
  key_name   = "${var.namespace}-${var.env}-key"
  public_key = file(var.public_key_path)

  tags = {
    Name = "${var.namespace}-${var.env}-key"
  }
}

module "network" {
  source           = "./modules/network"
  vpc_cidr         = var.vpc_cidr
  namespace        = var.namespace
  env              = var.env
  ssh_allowed_cidr = var.ssh_allowed_cidr
}

module "iam" {
  source    = "./modules/iam"
  namespace = var.namespace
  env       = var.env
}

module "fsx" {
  source            = "./modules/fsx"
  namespace         = var.namespace
  env               = var.env
  subnet_id         = module.network.subnet_id
  security_group_id = module.network.security_group_id
}

module "head_node" {
  source = "./modules/head-node"

  namespace            = var.namespace
  env                  = var.env
  instance_type        = var.head_node_instance_type
  subnet_id            = module.network.subnet_id
  security_group_id    = module.network.security_group_id
  iam_instance_profile = module.iam.head_node_instance_profile
  key_name             = aws_key_pair.hpc_key.key_name
  aws_region           = var.aws_region
  compute_instance_type = var.compute_instance_type
  max_compute_nodes    = var.max_compute_nodes
  launch_template_name = "${var.namespace}-${var.env}-compute-lt"
  slurm_db_password    = random_password.slurm_db.result
  fsx_dns_name         = module.fsx.dns_name
  fsx_mount_name       = module.fsx.mount_name
}

module "login_node" {
  source = "./modules/login-node"

  namespace            = var.namespace
  env                  = var.env
  instance_type        = "t3.small"
  subnet_id            = module.network.subnet_id
  security_group_id    = module.network.login_sg_id
  iam_instance_profile = module.iam.login_node_instance_profile
  key_name             = aws_key_pair.hpc_key.key_name
  aws_region           = var.aws_region
  max_compute_nodes    = var.max_compute_nodes
  head_node_private_ip = module.head_node.private_ip
  fsx_dns_name         = module.fsx.dns_name
  fsx_mount_name       = module.fsx.mount_name
}

module "compute_fleet" {
  source = "./modules/compute-fleet"

  namespace            = var.namespace
  env                  = var.env
  instance_type        = var.compute_instance_type
  subnet_id            = module.network.subnet_id
  security_group_id    = module.network.security_group_id
  iam_instance_profile = module.iam.compute_node_instance_profile
  key_name             = aws_key_pair.hpc_key.key_name
  aws_region           = var.aws_region
  max_compute_nodes    = var.max_compute_nodes
  fsx_dns_name         = module.fsx.dns_name
  fsx_mount_name       = module.fsx.mount_name
}

# Terminates Slurm-launched compute nodes (not in Terraform state) before
# VPC teardown. On destroy this runs first; on create it is a no-op.
resource "null_resource" "cleanup_compute_nodes" {
  triggers = {
    vpc_id    = module.network.vpc_id
    region    = var.aws_region
    namespace = var.namespace
    env       = var.env
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      INSTANCE_IDS=$(aws ec2 describe-instances \
        --region "${self.triggers.region}" \
        --filters \
          "Name=vpc-id,Values=${self.triggers.vpc_id}" \
          "Name=tag-key,Values=SlurmNodeName" \
          "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text)
      if [ -n "$INSTANCE_IDS" ] && [ "$INSTANCE_IDS" != "None" ]; then
        echo "Terminating Slurm compute nodes: $INSTANCE_IDS"
        aws ec2 terminate-instances --region "${self.triggers.region}" --instance-ids $INSTANCE_IDS
        echo "Waiting for termination..."
        aws ec2 wait instance-terminated --region "${self.triggers.region}" --instance-ids $INSTANCE_IDS
        echo "Done."
      else
        echo "No Slurm compute nodes to clean up."
      fi
      echo "Cleaning up SSM parameters..."
      for param in munge-key head-node-ip head-node-hostname; do
        aws ssm delete-parameter \
          --region "${self.triggers.region}" \
          --name "/hpc/${self.triggers.namespace}/${self.triggers.env}/$param" 2>/dev/null || true
      done
      echo "SSM cleanup done."
    EOT
  }

  depends_on = [module.network, module.head_node, module.compute_fleet, module.iam]
}
