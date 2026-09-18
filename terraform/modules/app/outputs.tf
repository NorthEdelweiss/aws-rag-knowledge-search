output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.api.repository_url
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.api.name
}

output "api_task_family" {
  value = aws_ecs_task_definition.api.family
}

output "job_task_families" {
  value = { for k, td in aws_ecs_task_definition.job : k => td.family }
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.api.name
}

output "task_role_arn" {
  value = aws_iam_role.task.arn
}

# --- cicd モジュール向け（許可ポリシーの Resource に使う） -------------------
output "ecr_repository_arn" {
  value = aws_ecr_repository.api.arn
}

output "service_arn" {
  value = aws_ecs_service.api.id # aws_ecs_service の id は ARN
}
