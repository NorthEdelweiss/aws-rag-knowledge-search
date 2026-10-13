# ============================================================================
# CI/CD 用 IAM：GitHub Actions → AWS を OIDC（一時クレデンシャル）で認証する
#
#   なぜ長期アクセスキーを GitHub Secrets に置かないか：
#     ① 漏洩しても STS が発行する一時クレデンシャル（既定 1 時間）は自然失効する
#     ② キーのローテーション運用そのものが無くなる
#     ③ 「どのリポジトリ・どのブランチからしか引き受けられないか」を IAM 側（信頼ポリシー）で縛れる
#   → 本プロジェクトは「Bedrock は国内 / DB は private / パスワードは Secrets Manager」と
#     一貫して長期秘密を置かない設計。CI に永久キーを置くとそこだけ穴になる。
#
#   流れ：Actions のジョブ → GitHub が署名した OIDC トークン（sub = repo:owner/repo:ref:refs/heads/main）
#         → sts:AssumeRoleWithWebIdentity → この Role の一時クレデンシャル → ECR push / ECS 再デプロイ
# ============================================================================

# --- ID プロバイダ（アカウントに 1 つ。URL がキー） ---------------------------
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"] # トークンの aud。configure-aws-credentials の既定値

  # GitHub の OIDC ルート証明書のサムプリント（2 世代分）。
  # 現在 AWS はこの発行者を自前の信頼ストアで検証するため値は参照されないが、引数として必要。
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

# --- 信頼ポリシー：このリポジトリのこのブランチからのみ AssumeRole 可 -------------
# GitHub の sub クレームは 2 形式ある（トラブルシュート記録#21）：
#   旧形式  repo:<owner>/<repo>:ref:refs/heads/<branch>
#   ID 付き repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:refs/heads/<branch>
# ID 付きは、リポジトリを削除して同名で作り直された場合（なりすまし）でも ID が一致しないため安全。
# 実際に届いた sub は CloudTrail の AssumeRoleWithWebIdentity イベント（userIdentity.userName）で確認できる。
locals {
  repo_parts = split("/", var.github_repository)
  sub_repo = (
    var.github_owner_id != "" && var.github_repository_id != ""
    ? "${local.repo_parts[0]}@${var.github_owner_id}/${local.repo_parts[1]}@${var.github_repository_id}"
    : var.github_repository
  )
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    sid     = "GitHubActionsOIDC"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # aud：トークンの宛先が AWS STS であること
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # sub：リポジトリとブランチを完全一致で限定（StringLike + "*" にすると別ブランチ/PR からも通ってしまう）
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.sub_repo}:ref:refs/heads/${var.github_branch}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${var.name_prefix}-github-deploy-role"
  description          = "Assumed by GitHub Actions (${var.github_repository}@${var.github_branch}) via OIDC to push images and redeploy ECS"
  assume_role_policy   = data.aws_iam_policy_document.github_assume.json
  max_session_duration = 3600 # 1 時間。ワークフロー 1 回に必要な最小
}

# --- 許可ポリシー：ECR の 1 リポジトリへ push + ECS の 1 サービスを再デプロイ ----------
data "aws_iam_policy_document" "deploy" {
  # GetAuthorizationToken はリソース指定不可（"*" 必須）
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushToApiRepo"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
    ]
    resources = [var.ecr_repository_arn]
  }

  # force-new-deployment（タスク定義は Terraform 管理のまま、同じ :latest を引き直させる）と完了待ち
  statement {
    sid = "EcsRedeployApiService"
    actions = [
      "ecs:UpdateService",
      "ecs:DescribeServices",
    ]
    resources = [var.ecs_service_arn]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "${var.name_prefix}-github-deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
