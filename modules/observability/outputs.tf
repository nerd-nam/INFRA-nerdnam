output "loki_bucket" { value = aws_s3_bucket.loki.bucket }
output "loki_role_arn" { value = aws_iam_role.loki.arn }
