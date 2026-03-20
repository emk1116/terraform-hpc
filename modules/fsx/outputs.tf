output "dns_name" {
  value = aws_fsx_lustre_file_system.hpc.dns_name
}

output "mount_name" {
  value = aws_fsx_lustre_file_system.hpc.mount_name
}
