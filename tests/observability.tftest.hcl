mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_s3_bucket" {
    override_during = plan
    defaults        = { arn = "arn:aws:s3:::nerdnam-dev-loki-082139775699-ap-northeast-2", id = "nerdnam-dev-loki-082139775699-ap-northeast-2" }
  }
}

variables {
  name         = "nerdnam-dev"
  region       = "ap-northeast-2"
  account_id   = "082139775699"
  cluster_name = "nerdnam-dev"
  cluster_arn  = "arn:aws:eks:ap-northeast-2:082139775699:cluster/nerdnam-dev"
}

run "loki_bucket_and_identity" {
  command = plan
  module { source = "./modules/observability" }

  assert {
    condition     = aws_s3_bucket.loki.bucket == "nerdnam-dev-loki-082139775699-ap-northeast-2"
    error_message = "Loki bucket 이름이 바뀌면 GitOps loki 설정과 bootstrap 이 함께 바뀌어야 합니다."
  }
  assert {
    condition = alltrue([aws_s3_bucket_public_access_block.loki.block_public_acls, aws_s3_bucket_public_access_block.loki.block_public_policy,
    aws_s3_bucket_public_access_block.loki.ignore_public_acls, aws_s3_bucket_public_access_block.loki.restrict_public_buckets])
    error_message = "로그 bucket 은 공개 접근을 모두 막아야 합니다."
  }
  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.loki.rule).expiration[0].days > var.log_retention_days
    error_message = "lifecycle 만료가 Loki 보존 기간보다 길어야 Loki 가 지우기 전에 데이터가 사라지지 않습니다."
  }
  assert {
    condition     = aws_eks_pod_identity_association.loki.namespace == "monitoring" && aws_eks_pod_identity_association.loki.service_account == "loki"
    error_message = "Loki 역할은 monitoring/loki ServiceAccount 에만 연결해야 합니다."
  }
  assert {
    condition = toset(flatten([for s in data.aws_iam_policy_document.loki_s3.statement : s.resources])) == toset([
      "arn:aws:s3:::nerdnam-dev-loki-082139775699-ap-northeast-2",
      "arn:aws:s3:::nerdnam-dev-loki-082139775699-ap-northeast-2/*",
    ])
    error_message = "Loki 는 자기 bucket 에만 접근해야 합니다."
  }
  assert {
    condition     = !contains(flatten([for s in data.aws_iam_policy_document.loki_s3.statement : s.actions]), "s3:*")
    error_message = "S3 권한을 와일드카드로 주지 않습니다."
  }
}
