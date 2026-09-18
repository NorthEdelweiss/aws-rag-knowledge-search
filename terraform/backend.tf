# ============================================================================
# リモート state（S3）。バケットは ./bootstrap で先に作っておく。
#   backend ブロックでは変数が使えない（Terraform の仕様）ためベタ書き。
#   use_lockfile = true → S3 の条件付き書き込みでロック（DynamoDB テーブル不要、TF 1.10+）
# ============================================================================
terraform {
  backend "s3" {
    bucket       = "kachi-rag-tfstate-2026"
    key          = "rag/terraform.tfstate"
    region       = "ap-northeast-1"
    encrypt      = true
    use_lockfile = true
  }
}
