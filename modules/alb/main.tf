variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "alb_sg_id" { type = string }
variable "acm_certificate_arn" { type = string }

# ----------------------------------------------------------------------------
# ALB
# ----------------------------------------------------------------------------

resource "aws_lb" "main" {
  name_prefix        = "titan"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  enable_http2               = true
  enable_deletion_protection = false

  tags = { Name = "${var.name_prefix}-alb" }
}

# ----------------------------------------------------------------------------
# Target group for the head node (jobui on port 80)
# ----------------------------------------------------------------------------

resource "aws_lb_target_group" "jobui" {
  name_prefix = "jobui"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/api/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }

  # Large uploads from the browser can take a while if they go through ALB;
  # however with presigned multipart to S3, the ALB path is only JSON API calls.
  # 60s idle is plenty.
  deregistration_delay = 30

  tags = { Name = "${var.name_prefix}-jobui-tg" }

  lifecycle {
    create_before_destroy = true
  }
}

# ----------------------------------------------------------------------------
# HTTPS listener
# ----------------------------------------------------------------------------

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.jobui.arn
  }
}

# HTTP → HTTPS redirect
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

output "dns_name" { value = aws_lb.main.dns_name }
output "zone_id" { value = aws_lb.main.zone_id }
output "arn" { value = aws_lb.main.arn }
output "https_url" { value = "https://${aws_lb.main.dns_name}" }
output "jobui_target_group_arn" { value = aws_lb_target_group.jobui.arn }
