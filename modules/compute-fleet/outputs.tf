output "launch_template_id" {
  value = aws_launch_template.compute.id
}

output "launch_template_name" {
  value = aws_launch_template.compute.name
}

output "asg_name" {
  value = aws_autoscaling_group.compute.name
}
