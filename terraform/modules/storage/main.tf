# ============================================================================
# storage モジュール：RAG 取込対象の文書バケット
#   公開ブロック全 ON / SSE-S3 / ACL 無効（BucketOwnerEnforced）。
#   読み取りは app モジュールの Task Role が docs/ 接頭辞に限定して許可する。
# ============================================================================

resource "aws_s3_bucket" "docs" {
  bucket = var.bucket_name

  # 練習環境：オブジェクトが残っていても terraform destroy で消せるようにする。
  # 本番では false（中身ごと消える事故を防ぐ）
  force_destroy = var.force_destroy

  tags = { Name = var.bucket_name }
}

resource "aws_s3_bucket_public_access_block" "docs" {
  bucket                  = aws_s3_bucket.docs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "docs" {
  bucket = aws_s3_bucket.docs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "docs" {
  bucket = aws_s3_bucket.docs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
