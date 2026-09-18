terraform {
  # backend "s3" の use_lockfile（S3 ネイティブロック、DynamoDB 不要）は 1.10 以降
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region

  # 全リソースに自動付与。コスト集計（Cost Explorer の Project タグ）と
  # 「これは Terraform 管理か手作業か」の識別に使う
  default_tags {
    tags = {
      Project   = "rag"
      ManagedBy = "terraform"
    }
  }
}
