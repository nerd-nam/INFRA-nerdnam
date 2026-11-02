output "plan_role_arn" { value = aws_iam_role.this["plan"].arn }
output "apply_role_arn" { value = aws_iam_role.this["apply"].arn }
output "apply_environment" { value = var.apply_environment }
