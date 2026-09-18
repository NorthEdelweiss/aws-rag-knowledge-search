# ============================================================================
# ALB（公開）→ ターゲットグループ（IP 型 / 8000 / ヘルスチェック /health）
#   Fargate(awsvpc) のタスクは ENI に直接 IP が付くので target_type = "ip"
# ============================================================================

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  idle_timeout               = 60
  drop_invalid_header_fields = true
  enable_deletion_protection = false # 練習環境。本番は true

  tags = { Name = "${var.name_prefix}-alb" }
}

resource "aws_lb_target_group" "api" {
  name        = "${var.name_prefix}-api-tg"
  vpc_id      = var.vpc_id
  target_type = "ip"
  protocol    = "HTTP"
  port        = 8000

  # 既定 300 秒 → 30 秒。デプロイ時の旧タスク退場を速くする
  deregistration_delay = 30

  health_check {
    protocol            = "HTTP"
    path                = "/health"
    port                = "traffic-port"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = { Name = "${var.name_prefix}-api-tg" }
}

# HTTP のみ（HTTPS は独自ドメイン + ACM 証明書が要るので作品公開時の改善点として残す）
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
