# apply 完了時に画面へ出る値。運用コマンドは PowerShell 5.1 で
# そのまま貼れる形（クォート地獄＝トラブルシュート記録#11 を避けるため、JSON を含まない）。

output "alb_dns_name" {
  description = "ALB の DNS 名（4-2）"
  value       = module.app.alb_dns_name
}

output "api_base_url" {
  value = "http://${module.app.alb_dns_name}"
}

output "ecr_repository_url" {
  value = module.app.ecr_repository_url
}

output "ecs_cluster_name" {
  value = module.app.cluster_name
}

output "ecs_service_name" {
  value = module.app.service_name
}

output "db_identifier" {
  value = module.db.db_identifier
}

output "db_endpoint" {
  value = module.db.endpoint
}

output "db_secret_arn" {
  value = module.db.secret_arn
}

output "docs_bucket_name" {
  value = module.storage.bucket_name
}

output "nat_enabled" {
  value = var.enable_nat
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "app_sg_id" {
  value = module.network.app_sg_id
}

output "job_task_definitions" {
  description = "ワンショットジョブ（DDL / 取込）のタスク定義 family。run_job.ps1 が使う"
  value       = module.app.job_task_families
}

# --- そのまま貼れる運用コマンド -------------------------------------------
output "cmd_push_image" {
  description = "ローカルの rag-api:latest イメージを Terraform 版 ECR へ入れる"
  # ⚠️ PowerShell 5.1 では `... | docker login --password-stdin` が 400 Bad Request になる（トラブルシュート記録#18）。
  #    サブ式 (aws ecr get-login-password ...) で直接渡す形にしている。
  value = <<-EOT
    docker login --username AWS --password (aws ecr get-login-password --region ${var.region}) ${split("/", module.app.ecr_repository_url)[0]}
    docker tag rag-api:latest ${module.app.ecr_repository_url}:latest
    docker push ${module.app.ecr_repository_url}:latest
  EOT
}

output "cmd_sync_docs" {
  description = "旧文書バケット → 新バケットへ文書をコピー"
  value       = "aws s3 sync s3://kachi-rag-docs-2026/${var.docs_prefix} s3://${module.storage.bucket_name}/${var.docs_prefix}"
}

output "cmd_run_init_db" {
  value = ".\\run_job.ps1 -Job init-db"
}

output "cmd_run_ingest" {
  value = ".\\run_job.ps1 -Job ingest"
}

# --- CI/CD ------------------------------------------------------------------
output "github_deploy_role_arn" {
  description = "GitHub Actions の role-to-assume。github_repository 未設定なら null"
  value       = one(module.cicd[*].role_arn)
}
