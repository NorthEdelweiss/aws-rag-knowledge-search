# コピーして terraform.tfvars にリネームして使う（terraform.tfvars は .gitignore 済み）。
# 既定値は variables.tf にあるので、変えたい行だけ残せばよい。
#
#   cp example.tfvars terraform.tfvars

# --- 消灯／点灯の既定（安全側＝消灯）-------------------------------------
# 点灯は lights.ps1 on が -var で上書きする。ここを true/1 にすると
# 素の `terraform apply` で NAT・タスクが立ち上がり課金が始まるので注意。
enable_nat        = false
app_desired_count = 0

# --- 名前（旧手作業環境 rag-* と衝突しないように）-----------------------
name_prefix      = "rag-tf"
docs_bucket_name = "kachi-rag-tf-docs-2026"

# --- 練習用の緩い設定（本番では逆にする）-----------------------------------
db_skip_final_snapshot         = true
db_secret_recovery_window_days = 0

# --- CI/CD（GitHub Actions OIDC）。公開リポジトリ名に合わせる。空なら IAM を作らない --------
# github_repository = "your-github-user/your-public-repo"
# github_branch     = "main"
# GitHub が ID 付きの sub を発行する場合（AssumeRoleWithWebIdentity が AccessDenied になる時）は
# CloudTrail のイベントに出た repo:<owner>@<owner_id>/<repo>@<repo_id> の数字を入れる
# github_owner_id      = "12345678"
# github_repository_id = "987654321"
