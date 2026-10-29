mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name         = "nerdnam-dev"
  region       = "ap-northeast-2"
  account_id   = "082139775699"
  cluster_name = "nerdnam-dev"
  cluster_arn  = "arn:aws:eks:ap-northeast-2:082139775699:cluster/nerdnam-dev"
}

# mock bucket 은 arn 을 임의 문자열로 만든다. 권한이 "자기 bucket" 만 가리키는지 보려면 실제 형식의 arn 이 필요하다.
override_resource {
  target          = aws_s3_bucket.store["loki"]
  override_during = plan
  values          = { arn = "arn:aws:s3:::nerdnam-dev-loki-082139775699-ap-northeast-2", id = "nerdnam-dev-loki-082139775699-ap-northeast-2" }
}
override_resource {
  target          = aws_s3_bucket.store["tempo"]
  override_during = plan
  values          = { arn = "arn:aws:s3:::nerdnam-dev-tempo-082139775699-ap-northeast-2", id = "nerdnam-dev-tempo-082139775699-ap-northeast-2" }
}

run "loki_and_tempo_stores" {
  command = plan
  module { source = "./modules/observability" }

  assert {
    condition = (aws_s3_bucket.store["loki"].bucket == "nerdnam-dev-loki-082139775699-ap-northeast-2"
    && aws_s3_bucket.store["tempo"].bucket == "nerdnam-dev-tempo-082139775699-ap-northeast-2")
    error_message = "bucket 이름이 바뀌면 GitOps loki·tempo 설정과 bootstrap 이 함께 바뀌어야 합니다."
  }
  assert {
    condition = alltrue(flatten([for b in aws_s3_bucket_public_access_block.store : [b.block_public_acls, b.block_public_policy,
    b.ignore_public_acls, b.restrict_public_buckets]]))
    error_message = "관측 bucket 은 공개 접근을 모두 막아야 합니다."
  }
  assert {
    condition = (one(aws_s3_bucket_lifecycle_configuration.store["loki"].rule).expiration[0].days > var.log_retention_days
    && one(aws_s3_bucket_lifecycle_configuration.store["tempo"].rule).expiration[0].days > var.trace_retention_days)
    error_message = "lifecycle 만료가 Loki·Tempo 보존 기간보다 길어야 앱이 지우기 전에 데이터가 사라지지 않습니다."
  }
  assert {
    condition = ({ for k, a in aws_eks_pod_identity_association.store : k => "${a.namespace}/${a.service_account}" }
    == { loki = "monitoring/loki", tempo = "monitoring/tempo" })
    error_message = "각 역할은 monitoring 의 자기 ServiceAccount(loki, tempo) 하나에만 연결해야 합니다."
  }
  assert {
    condition = alltrue([for k in ["loki", "tempo"] :
      toset(flatten([for s in data.aws_iam_policy_document.s3[k].statement : s.resources])) == toset([
        "arn:aws:s3:::nerdnam-dev-${k}-082139775699-ap-northeast-2",
        "arn:aws:s3:::nerdnam-dev-${k}-082139775699-ap-northeast-2/*",
    ])])
    error_message = "Loki·Tempo 는 각자 자기 bucket 에만 접근해야 합니다."
  }
  assert {
    condition     = !contains(flatten([for d in data.aws_iam_policy_document.s3 : [for s in d.statement : s.actions]]), "s3:*")
    error_message = "S3 권한을 와일드카드로 주지 않습니다."
  }
  assert {
    condition     = toset([for r in aws_iam_role.store : r.name]) == toset(["nerdnam-dev-loki", "nerdnam-dev-tempo"])
    error_message = "역할 이름은 IAM 실행자 정책 초안(nerdnam-dev-loki, nerdnam-dev-tempo)과 맞아야 합니다."
  }
}
