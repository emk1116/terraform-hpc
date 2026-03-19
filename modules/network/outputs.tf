output "subnet_id" {
  value = aws_subnet.hpc_subnet.id
}

output "security_group_id" {
  value = aws_security_group.hpc_sg.id
}

output "vpc_id" {
  value = aws_vpc.hpc_vpc.id
}
