output "role_arn" {
  description = "GitHub Actions の aws-actions/configure-aws-credentials に渡す role-to-assume"
  value       = aws_iam_role.deploy.arn
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}
