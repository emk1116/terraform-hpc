variable "name_prefix" { type = string }
variable "subnet_id" { type = string }
variable "security_group_ids" { type = list(string) }
variable "storage_capacity_gib" { type = number }
variable "s3_bucket_name" { type = string }

# ----------------------------------------------------------------------------
# FSx Lustre — SCRATCH_2 filesystem
# Throughput: 240 MB/s per 1200 GiB of capacity.
# ----------------------------------------------------------------------------

resource "aws_fsx_lustre_file_system" "main" {
  storage_capacity         = var.storage_capacity_gib
  subnet_ids               = [var.subnet_id]
  security_group_ids       = var.security_group_ids
  deployment_type          = "SCRATCH_2"
  file_system_type_version = "2.15"
  storage_type             = "SSD"

  tags = { Name = "${var.name_prefix}-fsx" }

  lifecycle {
    # FSx capacity changes require recreate
    create_before_destroy = false
  }
}

# ----------------------------------------------------------------------------
# Data repository association (optional) — lazy-load weights from S3.
# Commented by default. Uncomment and set a prefix to enable.
# When enabled, files under s3://<bucket>/models/ appear on FSx at /fsx/models/
# and are fetched from S3 on first access.
# ----------------------------------------------------------------------------

# resource "aws_fsx_data_repository_association" "models" {
#   file_system_id       = aws_fsx_lustre_file_system.main.id
#   data_repository_path = "s3://${var.s3_bucket_name}/models/"
#   file_system_path     = "/models"
#
#   s3 {
#     auto_export_policy {
#       events = ["NEW", "CHANGED", "DELETED"]
#     }
#     auto_import_policy {
#       events = ["NEW", "CHANGED", "DELETED"]
#     }
#   }
# }

output "id" { value = aws_fsx_lustre_file_system.main.id }
output "dns_name" { value = aws_fsx_lustre_file_system.main.dns_name }
output "mount_name" { value = aws_fsx_lustre_file_system.main.mount_name }
output "arn" { value = aws_fsx_lustre_file_system.main.arn }
