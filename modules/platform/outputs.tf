output "secret_arns" { value = { for name, secret in aws_secretsmanager_secret.workload : name => secret.arn } }
output "role_arns" { value = { for name, role in aws_iam_role.controller : name => role.arn } }
output "route53_zone_id" { value = var.route53_zone_id }
