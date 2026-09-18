output "db_identifier" {
  value = aws_db_instance.this.identifier
}

output "endpoint" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

# app モジュールが IAM（GetSecretValue）とタスク定義（valueFrom）で使う。
# ARN 末尾のランダム 6 文字（手作業版の -4DuBbl）も Terraform が正確に渡す。
output "secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}

output "secret_name" {
  value = aws_secretsmanager_secret.db.name
}
