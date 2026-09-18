# terraform/ — 社内ナレッジ検索 RAG の IaC

先にコンソールで手作業構築した環境を、Terraform で丸ごとコード化したもの。
`terraform apply` 一発で **VPC → RDS(pgvector) → ECS Fargate → ALB → IAM → Secrets → S3** まで揃う。

```
                 ┌──────────── network ────────────┐
 Internet ──▶ ALB(public subnet ×2) ──▶ ECS Fargate(private ×2) ──▶ RDS PostgreSQL 18 + pgvector
                 │  alb-sg → app-sg → rds-sg       │        │
                 │  NAT(任意) / S3 Gateway Endpoint │        ├──▶ Bedrock (jp.claude-sonnet-4-6 / titan-embed-v2)
                 └─────────────────────────────────┘        └──▶ S3 docs/（取込元）
        db: RDS + Secrets Manager(random_password)   storage: 文書バケット   app: ECR/ECS/ALB/IAM/Logs
```

## ディレクトリ

| パス | 役割 |
|---|---|
| `bootstrap/` | state 用 S3 バケットだけを作る（local state、初回 1 回のみ） |
| `providers.tf` / `backend.tf` | provider・バージョン固定・S3 backend（`use_lockfile` でロック） |
| `variables.tf` / `example.tfvars` | 入力。`example.tfvars` を `terraform.tfvars` にコピーして使う（tfvars は git 管理外） |
| `main.tf` | 5 モジュールの配線（出力→入力のみ。ID のベタ書きなし） |
| `outputs.tf` | ALB DNS、ECR URL、そのまま貼れる運用コマンド |
| `modules/network` | VPC / サブネット×4 / IGW / NAT(count) / RT×2 / SG×3 / S3 Gateway EP |
| `modules/db` | DB サブネットグループ / RDS / `random_password` → Secrets Manager |
| `modules/storage` | 文書バケット（公開ブロック・SSE・ACL 無効） |
| `modules/app` | ECR(+lifecycle) / Logs / クラスター / タスク定義(API + ジョブ×2) / サービス / ALB / IAM ×2 |
| `modules/cicd` | GitHub Actions 用 OIDC プロバイダ + deploy ロール（`github_repository` を設定した時だけ作成） |
| `lights.ps1` | 点灯 `on`（RDS 起動 + NAT + タスク 1）／消灯 `off`／`status` |
| `run_job.ps1` | `init-db`（DDL）・`ingest`（文書取込）を Fargate で 1 回実行してログ表示 |

## 使い方

```powershell
# 0. 初回のみ：state バケット
cd terraform\bootstrap; terraform init; terraform apply; cd ..

# 1. 初回のみ：入力ファイルと backend 初期化
copy example.tfvars terraform.tfvars
terraform init            # "Successfully configured the backend s3"

# 2. 構築（既定は消灯状態：NAT なし・タスク 0。RDS だけは作成される）
terraform plan
terraform apply

# 3. イメージと文書を入れる（出力に手順が出る）
terraform output -raw cmd_push_image
terraform output -raw cmd_sync_docs

# 4. 点灯 → DDL → 取込 → 動作確認
.\lights.ps1 on
.\run_job.ps1 -Job init-db
.\run_job.ps1 -Job ingest
..\scripts\ask.ps1 -Alb (terraform output -raw alb_dns_name) -Question "テレワークの申請手順は？"

# 5. 消灯（NAT 削除・タスク 0・RDS 停止）／全部消す
.\lights.ps1 off
terraform destroy
```

⚠️ PowerShell 5.1 では `-var-file=example.tfvars` や `-target=module.network` のように `=` の後に `.` を含む引数が分割される
（`Too many command line arguments` / `Invalid target "module"`）。`-var-file example.tfvars`、`-target module.network` とスペース区切りで渡す。
同じく `... | docker login --password-stdin` は stdin 末尾の CR で 400 になるため、`cmd_push_image` は `--password (aws ecr get-login-password ...)` 形式にしている。

## 設計判断

1. **state はリモート + ロック + バージョニング**：`backend "s3"` に `use_lockfile = true`（S3 条件付き書き込み、DynamoDB 不要）。state には DB パスワードが平文で入るため、バケットは暗号化・公開ブロック・`prevent_destroy`。
2. **モジュール分割は「変更の波及範囲」で切る**：network を触っても db/app のコードは変わらない。モジュール間は output → variable のみ。
3. **秘密情報はコードに書かない**：`random_password` → RDS と Secrets Manager へ Terraform が直接流す。人は平文を見ない。アプリは ECS の `secrets`（`valueFrom "<arn>:host::"`）で受け取る。
4. **消灯をコードで表現**：`enable_nat` の count で NAT/EIP/デフォルトルートを 3 点同時に増減。手作業時代の「blackhole ルートが残る」問題が構造的に消える。`app_desired_count` も同様。
5. **最小権限を 2 ロールで分離**：Execution Role（ECR pull / Logs / この 1 シークレットの GetSecretValue）と Task Role（モデル ARN 限定の Bedrock / `docs/*` 限定の S3）。信頼ポリシーに `aws:SourceAccount` / `aws:SourceArn`。
6. **コスト衛生をデフォルトに**：ECR lifecycle（直近 10 個）、Logs 保持 14 日、Performance Insights 無料枠、単一 NAT / 単一 AZ RDS（本番なら真っ先に冗長化）。
7. **ジョブは JSON overrides でなくタスク定義で持つ**：`init-db` / `ingest` を `for_each` で生成。CLI から呼ぶ時にクォート問題を踏まない。
8. **import ではなく再構築**：手作業環境は `-tf` 接頭辞の新環境で並走させ、動作確認後に旧環境を削除。state と実体のズレを持ち込まない。
9. **CI にも長期キーを置かない**：GitHub Actions は OIDC で `rag-tf-github-deploy-role` を引き受ける（`modules/cicd`）。信頼ポリシーの `sub` を `repo:<owner>/<repo>:ref:refs/heads/main` に**完全一致**で縛り、許可は ECR の 1 リポジトリへの push と ECS の 1 サービスの `UpdateService` だけ。タスク定義は Terraform 管理のまま、CI は `--force-new-deployment` で `:latest` を引き直させる（設定は IaC、コードだけ CI、で責務を分ける）。

## 未対応（次の改善点）

- HTTPS（独自ドメイン + ACM）、WAF
- Interface Endpoint（ECR/Secrets/Logs/Bedrock）で NAT 依存を減らす
- RDS Multi-AZ / 削除保護 / 最終スナップショット（本番値は variables.tf のコメント参照）
- フロント（S3 + CloudFront、手作業構築）のコード化
- staging / production の分離（ディレクトリ or workspace）
