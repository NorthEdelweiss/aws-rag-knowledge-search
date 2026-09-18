# ============================================================================
# ECR / CloudWatch Logs / ECS クラスター / タスク定義（API + ワンショットジョブ）/ サービス
# ============================================================================

# ---------------------------------------------------------------------------
# ECR + ライフサイクル（3-4：レイヤーは無限に溜まる。直近 10 個だけ残す）
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "api" {
  name                 = "${var.name_prefix}-api"
  image_tag_mutability = "MUTABLE" # CI/CD 導入後は IMMUTABLE + digest 固定が本命（トラブルシュート記録#13）

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # 練習環境：イメージが残っていても destroy できる
  force_delete = true
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep only the last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------------------
# ログ：手作業版は awslogs-create-group で無期限グループが勝手に出来ていた。
#       Terraform で明示的に作り、保持期間を付ける。
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.name_prefix}-api"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# クラスター
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled" # 有効化はメトリクス課金あり。必要になったら enhanced に
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

# ---------------------------------------------------------------------------
# タスク定義の共通部品
# ---------------------------------------------------------------------------
locals {
  image = var.container_image != "" ? var.container_image : "${aws_ecr_repository.api.repository_url}:latest"

  # Secrets Manager の JSON キー → コンテナ環境変数名。
  # valueFrom "<secret arn>:<json key>::" の形（バージョン・ステージ省略＝最新）
  db_secret_keys = {
    host     = "DB_HOST"
    port     = "DB_PORT"
    username = "DB_USER"
    password = "DB_PASSWORD"
    dbname   = "DB_NAME"
  }
  db_secrets = [
    for key, env_name in local.db_secret_keys : {
      name      = env_name
      valueFrom = "${var.db_secret_arn}:${key}::"
    }
  ]

  common_env = [
    { name = "AWS_REGION", value = var.region },
    { name = "BEDROCK_MODEL_ID", value = var.bedrock_model_id },
    { name = "BEDROCK_EMBED_MODEL_ID", value = var.bedrock_embed_model_id },
  ]

  # ワンショットジョブ（run-task で 1 回だけ動かす）。同じイメージ・同じロール、command だけ違う。
  # 手作業版は run-task の JSON overrides で command を上書きしていたが、
  # PowerShell 5.1 のクォート問題（トラブルシュート記録#11）を避けるため、ジョブごとに定義を持つ。
  jobs = {
    "init-db" = ["python", "init_db.py"] # pgvector 拡張 + documents 表（冪等）
    "ingest"  = ["python", "ingest.py"]  # S3 docs/ → 分割 → Titan → pgvector（冪等）
  }
}

# ---------------------------------------------------------------------------
# API タスク定義（サービスが常駐させる）
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name_prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.task_exec.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "rag-api"
    image     = local.image
    essential = true

    portMappings = [{
      name          = "api-8000-tcp"
      containerPort = 8000
      protocol      = "tcp"
      appProtocol   = "http"
    }]

    environment = concat(local.common_env, [
      { name = "ALLOWED_ORIGINS", value = var.allowed_origins },
      { name = "RAG_TOP_K", value = tostring(var.rag_top_k) },
      { name = "RAG_MIN_SIMILARITY", value = tostring(var.rag_min_similarity) },
    ])

    secrets = local.db_secrets

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.api.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "api"
      }
    }
  }])
}

# ---------------------------------------------------------------------------
# ジョブ用タスク定義（for_each で init-db / ingest の 2 本）
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "job" {
  for_each = local.jobs

  family                   = "${var.name_prefix}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.task_exec.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "rag-job"
    image     = local.image
    essential = true
    command   = each.value

    # ingest.py は --bucket / --prefix 省略時に環境変数を読む → バケット名をコマンドに埋め込まない
    environment = concat(local.common_env, [
      { name = "DOCS_BUCKET", value = var.docs_bucket_name },
      { name = "DOCS_PREFIX", value = var.docs_prefix },
    ])

    secrets = local.db_secrets

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.api.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = each.key
      }
    }
  }])
}

# ---------------------------------------------------------------------------
# サービス：プライベートサブネット / パブリック IP なし / ALB 配下 / サーキットブレーカー
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "api" {
  name             = "${var.name_prefix}-api-service"
  cluster          = aws_ecs_cluster.this.id
  task_definition  = aws_ecs_task_definition.api.arn
  desired_count    = var.desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  # 新リビジョンが起動失敗を繰り返したら自動で前版へ戻す
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  health_check_grace_period_seconds = 60
  availability_zone_rebalancing     = "ENABLED"
  enable_ecs_managed_tags           = true
  propagate_tags                    = "SERVICE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.app_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "rag-api"
    container_port   = 8000
  }

  # リスナーが無い TG にサービスを紐付けると作成に失敗する / ロールの権限が揃う前にタスクが走ると失敗する
  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy_attachment.task_exec_managed,
    aws_iam_role_policy.task_exec_secrets,
  ]
}
