# ============================================================================
# bootstrap: Terraform の state を置く S3 バケットだけを作る（鶏と卵の解消）
#
#   本体（../）は backend "s3" を使うが、その S3 バケット自体は
#   Terraform が動き出す前に存在していなければならない。
#   → このディレクトリだけは local state（terraform.tfstate がここに出来る。.gitignore 済み）
#   → 実行は一度だけ： cd terraform/bootstrap && terraform init && terraform apply
#
#   設計ポイント：state は「どのリソースを作ったか」の台帳。チームでは
#   ①リモート（S3）に置いて共有 ②ロックで同時 apply を防ぐ ③バージョニングで壊れた時に戻す。
# ============================================================================

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "rag"
      ManagedBy = "terraform-bootstrap"
    }
  }
}

variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "state_bucket_name" {
  description = "Terraform state 用バケット名（S3 はグローバルで一意）。本体の backend.tf と一致させる"
  type        = string
  default     = "kachi-rag-tfstate-2026"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket_name

  # state を失うと「何を作ったか」が分からなくなる。誤 destroy を Terraform 側で拒否する
  lifecycle {
    prevent_destroy = true
  }
}

# ⚠️ 必須：state を書き壊した時に前の版へ戻せる
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# state には DB パスワード等の機密値が平文で入る → 暗号化 + 公開ブロックは前提
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "state_bucket_name" {
  value = aws_s3_bucket.tfstate.bucket
}
