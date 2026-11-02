output "ai_role_arn" { value = aws_iam_role.ai.arn }
output "ci_role_arns" { value = { for k, r in aws_iam_role.ci : k => r.arn } }
output "github_oidc_provider_arn" { value = aws_iam_openid_connect_provider.github.arn }
