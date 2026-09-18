# ============================================================================
# IAM：ECS の 2 つのロール（混同しやすいので区別を明記）
#   Task Execution Role … ECS エージェントが使う。ECR pull / ログ書き込み / Secrets 取得
#   Task Role           … コンテナ内のアプリが使う。Bedrock 呼び出し / S3 文書読み取り
#   → アプリに Secrets 取得権限は与えない（注入は ECS がやる）。逆も同様。
# ============================================================================

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # "jp.anthropic.claude-sonnet-4-6" → "anthropic.claude-sonnet-4-6"
  # inference profile は裏で基盤モデルを呼ぶため、profile と基盤モデル両方の ARN が必要
  claude_base_model_id = replace(var.bedrock_model_id, "/^[a-z]{2}\\./", "")
}

# --- 信頼ポリシー：ecs-tasks だけが引き受け可。confused deputy 対策の条件付き ----
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${var.region}:${local.account_id}:*"]
    }
  }
}

# ---------------------------------------------------------------------------
# Task Execution Role
# ---------------------------------------------------------------------------
resource "aws_iam_role" "task_exec" {
  name               = "${var.name_prefix}-task-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "task_exec_managed" {
  role       = aws_iam_role.task_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "task_exec_secrets" {
  statement {
    sid       = "ReadDbCredentials"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn] # この 1 シークレットだけ
  }
}

resource "aws_iam_role_policy" "task_exec_secrets" {
  name   = "${var.name_prefix}-read-db-secret"
  role   = aws_iam_role.task_exec.id
  policy = data.aws_iam_policy_document.task_exec_secrets.json
}

# ---------------------------------------------------------------------------
# Task Role
# ---------------------------------------------------------------------------
resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# Bedrock：モデル単位で限定（トラブルシュート記録#14：Titan を足し忘れて AccessDenied → 最小権限が機能した証拠）
data "aws_iam_policy_document" "task_bedrock" {
  statement {
    sid = "InvokeModels"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = concat(
      ["arn:aws:bedrock:${var.region}:${local.account_id}:inference-profile/${var.bedrock_model_id}"],
      [for r in var.bedrock_profile_regions : "arn:aws:bedrock:${r}::foundation-model/${local.claude_base_model_id}*"],
      ["arn:aws:bedrock:${var.region}::foundation-model/${var.bedrock_embed_model_id}"],
    )
  }
}

resource "aws_iam_role_policy" "task_bedrock" {
  name   = "${var.name_prefix}-bedrock-invoke"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_bedrock.json
}

# S3：文書バケットの docs/ 接頭辞だけ List/Get
data "aws_iam_policy_document" "task_s3_docs" {
  statement {
    sid       = "ListDocs"
    actions   = ["s3:ListBucket"]
    resources = [var.docs_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [var.docs_prefix, "${var.docs_prefix}*"]
    }
  }

  statement {
    sid       = "ReadDocs"
    actions   = ["s3:GetObject"]
    resources = ["${var.docs_bucket_arn}/${var.docs_prefix}*"]
  }
}

resource "aws_iam_role_policy" "task_s3_docs" {
  name   = "${var.name_prefix}-s3-docs-read"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_s3_docs.json
}
