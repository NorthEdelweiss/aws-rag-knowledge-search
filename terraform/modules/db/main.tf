# ============================================================================
# db モジュール：RDS PostgreSQL（pgvector）/ DB サブネットグループ / Secrets Manager
#
# パスワードの扱い（設計ポイント）：
#   × コードや tfvars に平文で書く
#   ○ random_password で生成 → RDS と Secrets Manager の両方へ Terraform が直接流す
#   → 人間は一度も平文を見ない。アプリは ECS の secrets 注入で受け取る。
#   ⚠️ 副作用：生成値は state に入る。だから state バケットは暗号化＋非公開＋バージョニング。
# ============================================================================

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

resource "random_password" "master" {
  length  = 32
  special = true
  # RDS が禁止する文字（/ @ " 空白）を除いた記号だけを使う
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_db_subnet_group" "this" {
  name        = "${var.name_prefix}-db-subnet-group"
  description = "private subnets for ${var.name_prefix} RDS"
  subnet_ids  = var.subnet_ids

  tags = { Name = "${var.name_prefix}-db-subnet-group" }
}

resource "aws_db_instance" "this" {
  identifier = "${var.name_prefix}-db"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true # 既定の aws/rds キー

  db_name  = var.db_name
  username = var.username
  password = random_password.master.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false
  multi_az               = false # 単一 AZ（コスト優先。本番なら true が第一の改善点）

  backup_retention_period = 7
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade = true
  apply_immediately          = true

  performance_insights_enabled          = true
  performance_insights_retention_period = 7 # 無料枠

  deletion_protection       = false
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name_prefix}-db-final"

  tags = { Name = "${var.name_prefix}-db" }
}

# ---------------------------------------------------------------------------
# Secrets Manager：RDS 型シークレットと同じ 7 キーの JSON にしておく
#   （ECS タスク定義の valueFrom "<arn>:host::" 等のキー参照がそのまま使える）
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "db" {
  name        = "${var.name_prefix}/db/credentials"
  description = "RDS master credentials for ${var.name_prefix} (managed by Terraform)"

  # destroy 後すぐ同名で作り直せるように猶予 0（本番は 7〜30 で誤削除に備える）
  recovery_window_in_days = var.secret_recovery_days

  tags = { Name = "${var.name_prefix}-db-credentials" }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    engine               = "postgres"
    host                 = aws_db_instance.this.address
    port                 = aws_db_instance.this.port
    username             = aws_db_instance.this.username
    password             = random_password.master.result
    dbname               = aws_db_instance.this.db_name
    dbInstanceIdentifier = aws_db_instance.this.identifier
  })
}
