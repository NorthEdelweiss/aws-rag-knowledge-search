# ----------------------------------------------------------------------------
# 共通
# ----------------------------------------------------------------------------
variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "name_prefix" {
  description = "全リソース名の接頭辞。手作業で作った旧環境（rag-*）と共存させるため既定は rag-tf"
  type        = string
  default     = "rag-tf"
}

# ----------------------------------------------------------------------------
# network
# ----------------------------------------------------------------------------
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  description = "使用する AZ（2 つ）。サブネット CIDR の並びと対応させる"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "enable_nat" {
  description = "NAT Gateway を作るか。false なら NAT/EIP/デフォルトルートを持たない（≒消灯）。時間課金なので既定 false"
  type        = bool
  default     = false
}

# ----------------------------------------------------------------------------
# db
# ----------------------------------------------------------------------------
variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_engine_version" {
  description = "PostgreSQL バージョン。pgvector 0.8 系は 18 で利用可"
  type        = string
  default     = "18.3"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_name" {
  type    = string
  default = "ragdb"
}

variable "db_username" {
  type    = string
  default = "raguser"
}

variable "db_skip_final_snapshot" {
  description = "destroy 時に最終スナップショットを取らない。練習環境は true、本番は false にする"
  type        = bool
  default     = true
}

variable "db_secret_recovery_window_days" {
  description = "Secrets Manager 削除の猶予日数。0 で即時削除（destroy→apply の反復練習用）。本番は 7〜30"
  type        = number
  default     = 0
}

# ----------------------------------------------------------------------------
# storage（RAG 文書バケット）
# ----------------------------------------------------------------------------
variable "docs_bucket_name" {
  description = "RAG 取込対象の文書バケット名（グローバル一意）"
  type        = string
  default     = "kachi-rag-tf-docs-2026"
}

variable "docs_prefix" {
  description = "文書を置くキー接頭辞。IAM の ListBucket/GetObject もこの範囲に限定する"
  type        = string
  default     = "docs/"
}

# ----------------------------------------------------------------------------
# app（ECS / ALB / IAM）
# ----------------------------------------------------------------------------
variable "app_desired_count" {
  description = "API タスク数。0 で停止（消灯）、1 で稼働"
  type        = number
  default     = 0
}

variable "container_image" {
  description = "タスクが使うイメージ URI。空なら Terraform が作る ECR の :latest を使う"
  type        = string
  default     = ""
}

variable "bedrock_model_id" {
  description = "回答生成モデル（国内 inference profile。データを国外に出さない）"
  type        = string
  default     = "jp.anthropic.claude-sonnet-4-6"
}

variable "bedrock_profile_regions" {
  description = "jp. inference profile が裏で呼び分ける基盤モデルのリージョン（IAM の Resource に必要）"
  type        = list(string)
  default     = ["ap-northeast-1", "ap-northeast-3"]
}

variable "bedrock_embed_model_id" {
  type    = string
  default = "amazon.titan-embed-text-v2:0"
}

variable "rag_top_k" {
  type    = number
  default = 5
}

variable "rag_min_similarity" {
  type    = number
  default = 0.25
}

variable "allowed_origins" {
  description = "CORS 許可オリジン（カンマ区切り、例: https://dxxxx.cloudfront.net）。空＝ブラウザからのクロスオリジン呼び出しを全拒否"
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "CloudWatch Logs 保持日数（手作業版は無期限＝コスト垂れ流しだった）"
  type        = number
  default     = 14
}

# ----------------------------------------------------------------------------
# cicd（GitHub Actions OIDC）
# ----------------------------------------------------------------------------
variable "github_repository" {
  description = "GitHub Actions からの deploy を許可するリポジトリ（owner/repo）。空文字なら CI/CD 用 IAM を作らない"
  type        = string
  default     = ""
}

variable "github_branch" {
  description = "deploy を許可するブランチ。信頼ポリシーの sub を refs/heads/<branch> に完全一致で縛る"
  type        = string
  default     = "main"
}
