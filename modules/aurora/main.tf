variable "name_prefix" { type = string }
variable "team_name" { type = string }
variable "vpc_id" { type = string }
variable "db_subnet_ids" { type = list(string) }
variable "primary_az" { type = string }
variable "allowed_sg_ids" { type = list(string) }
variable "min_capacity_acu" { type = number }
variable "max_capacity_acu" { type = number }
variable "backup_retention_days" { type = number }

# ----------------------------------------------------------------------------
# Security group — allow :3306 from head_node + compute SGs only
# ----------------------------------------------------------------------------

resource "aws_security_group" "aurora" {
  name_prefix = "${var.name_prefix}-aurora-"
  description = "Aurora MySQL — reachable from head/compute only"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = toset(var.allowed_sg_ids)
    content {
      description     = "MySQL from allowed SG"
      from_port       = 3306
      to_port         = 3306
      protocol        = "tcp"
      security_groups = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-aurora-sg" }
}

# ----------------------------------------------------------------------------
# DB subnet group — Aurora requires at least 2 subnets in different AZs
# even for single-AZ deployment. We use the provided subnets; placement
# is forced to primary_az via availability_zones on the instance.
# ----------------------------------------------------------------------------

resource "aws_db_subnet_group" "aurora" {
  name_prefix = "${var.name_prefix}-aurora-"
  subnet_ids  = var.db_subnet_ids
  tags        = { Name = "${var.name_prefix}-aurora-subnet-group" }
}

# ----------------------------------------------------------------------------
# KMS key for Aurora encryption at rest
# ----------------------------------------------------------------------------

resource "aws_kms_key" "aurora" {
  description             = "${var.name_prefix} Aurora encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = { Name = "${var.name_prefix}-aurora-kms" }
}

resource "aws_kms_alias" "aurora" {
  name          = "alias/${var.name_prefix}-aurora"
  target_key_id = aws_kms_key.aurora.key_id
}

# ----------------------------------------------------------------------------
# Secrets Manager — master password, slurm user password, jobui user password
# ----------------------------------------------------------------------------

resource "random_password" "master" {
  length  = 32
  special = true
  # Aurora MySQL disallows / @ " and space in master password
  override_special = "!#$%&*()-_=+[]{}<>?"
}

resource "random_password" "slurm_user" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>?"
}

resource "random_password" "jobui_rw_user" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>?"
}

resource "aws_secretsmanager_secret" "master" {
  name_prefix = "${var.name_prefix}-aurora-master-"
  description = "Aurora master password for ${var.name_prefix}"
  kms_key_id  = aws_kms_key.aurora.arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "master" {
  secret_id = aws_secretsmanager_secret.master.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.master.result
  })
}

resource "aws_secretsmanager_secret" "slurm_user" {
  name_prefix             = "${var.name_prefix}-aurora-slurm-"
  description             = "MySQL user for slurmdbd"
  kms_key_id              = aws_kms_key.aurora.arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "slurm_user" {
  secret_id = aws_secretsmanager_secret.slurm_user.id
  secret_string = jsonencode({
    username = "slurm"
    password = random_password.slurm_user.result
    database = "slurm_acct_db"
  })
}

resource "aws_secretsmanager_secret" "jobui_rw" {
  name_prefix             = "${var.name_prefix}-aurora-jobui-"
  description             = "MySQL user for jobui app (read/write on jobui DB, read-only on slurm_acct_db)"
  kms_key_id              = aws_kms_key.aurora.arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "jobui_rw" {
  secret_id = aws_secretsmanager_secret.jobui_rw.id
  secret_string = jsonencode({
    username = "jobui_rw"
    password = random_password.jobui_rw_user.result
    database = "jobui"
  })
}

# ----------------------------------------------------------------------------
# Aurora cluster
# ----------------------------------------------------------------------------

resource "aws_rds_cluster" "main" {
  cluster_identifier          = "${var.name_prefix}-aurora"
  engine                      = "aurora-mysql"
  engine_mode                 = "provisioned"
  engine_version              = "8.0.mysql_aurora.3.07.1"
  database_name               = "slurm_acct_db"
  master_username             = "admin"
  master_password             = random_password.master.result
  db_subnet_group_name        = aws_db_subnet_group.aurora.name
  vpc_security_group_ids      = [aws_security_group.aurora.id]
  storage_encrypted           = true
  kms_key_id                  = aws_kms_key.aurora.arn
  backup_retention_period     = var.backup_retention_days
  preferred_backup_window     = "03:00-05:00"
  skip_final_snapshot         = true
  deletion_protection         = false
  apply_immediately           = true

  # Placement — Aurora Serverless v2 instance lands in primary_az
  availability_zones = [var.primary_az]

  serverlessv2_scaling_configuration {
    min_capacity = var.min_capacity_acu
    max_capacity = var.max_capacity_acu
  }

  enabled_cloudwatch_logs_exports = ["error", "slowquery", "audit"]

  tags = { Name = "${var.name_prefix}-aurora" }

  lifecycle {
    ignore_changes = [availability_zones]
  }
}

resource "aws_rds_cluster_instance" "writer" {
  identifier          = "${var.name_prefix}-aurora-writer"
  cluster_identifier  = aws_rds_cluster.main.id
  instance_class      = "db.serverless"
  engine              = aws_rds_cluster.main.engine
  engine_version      = aws_rds_cluster.main.engine_version
  publicly_accessible = false
  availability_zone   = var.primary_az

  performance_insights_enabled = true

  tags = { Name = "${var.name_prefix}-aurora-writer" }
}

# ----------------------------------------------------------------------------
# Bootstrap: create the jobui database + two MySQL users
# Runs once via a null_resource + AWS CLI rds-data API is NOT used (serverless v2
# doesn't support Data API). Instead, we emit a SQL script that the head node
# runs on first boot.
# ----------------------------------------------------------------------------

locals {
  bootstrap_sql = <<-SQL
    -- Create the jobui database
    CREATE DATABASE IF NOT EXISTS jobui
      DEFAULT CHARACTER SET utf8mb4
      DEFAULT COLLATE utf8mb4_unicode_ci;

    -- Slurm user: full rights on slurm_acct_db
    CREATE USER IF NOT EXISTS 'slurm'@'%' IDENTIFIED BY '__SLURM_PASSWORD__';
    GRANT ALL PRIVILEGES ON slurm_acct_db.* TO 'slurm'@'%';

    -- jobui_rw user: full rights on jobui, SELECT-only on slurm_acct_db
    CREATE USER IF NOT EXISTS 'jobui_rw'@'%' IDENTIFIED BY '__JOBUI_PASSWORD__';
    GRANT ALL PRIVILEGES ON jobui.* TO 'jobui_rw'@'%';
    GRANT SELECT ON slurm_acct_db.* TO 'jobui_rw'@'%';

    FLUSH PRIVILEGES;
  SQL
}

# Expose the bootstrap SQL to the head-node module via an output;
# the head node runs it on first boot via a systemd oneshot service.
output "bootstrap_sql" {
  description = "SQL to create databases + scoped users. Head node runs this on first boot, substituting passwords from Secrets Manager."
  value       = local.bootstrap_sql
  sensitive   = true
}

# ----------------------------------------------------------------------------
# Outputs
# ----------------------------------------------------------------------------

output "writer_endpoint" { value = aws_rds_cluster.main.endpoint }
output "reader_endpoint" { value = aws_rds_cluster.main.reader_endpoint }
output "port" { value = aws_rds_cluster.main.port }
output "cluster_resource_id" { value = aws_rds_cluster.main.cluster_resource_id }

output "master_password_secret_arn" { value = aws_secretsmanager_secret.master.arn }
output "slurm_db_password_secret_arn" { value = aws_secretsmanager_secret.slurm_user.arn }
output "jobui_db_password_secret_arn" { value = aws_secretsmanager_secret.jobui_rw.arn }

output "kms_key_arn" { value = aws_kms_key.aurora.arn }
output "security_group_id" { value = aws_security_group.aurora.id }
