output "loki_bucket" { value = aws_s3_bucket.store["loki"].bucket }
output "loki_role_arn" { value = aws_iam_role.store["loki"].arn }
output "tempo_bucket" { value = aws_s3_bucket.store["tempo"].bucket }
output "tempo_role_arn" { value = aws_iam_role.store["tempo"].arn }
