resource "aws_fsx_lustre_file_system" "hpc" {
  storage_capacity   = 1200
  subnet_ids         = [var.subnet_id]
  security_group_ids = [var.security_group_id]
  deployment_type    = "SCRATCH_1"

  tags = {
    Name       = "${var.namespace}-${var.env}-fsx"
    AutoDelete = "true"
  }
}
