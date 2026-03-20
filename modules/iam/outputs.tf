output "head_node_instance_profile" {
  value = aws_iam_instance_profile.head_node.name
}

output "compute_node_instance_profile" {
  value = aws_iam_instance_profile.compute_node.name
}

output "compute_node_role_arn" {
  value = aws_iam_role.compute_node.arn
}

output "login_node_instance_profile" {
  value = aws_iam_instance_profile.login_node.name
}
