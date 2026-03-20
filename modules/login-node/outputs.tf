output "public_ip" {
  value = aws_eip.login_node.public_ip
}

output "private_ip" {
  value = aws_instance.login_node.private_ip
}
