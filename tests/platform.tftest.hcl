mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}
run "controller_identity_and_secret_metadata" {
  command = plan
  module { source = "./modules/platform" }
  variables {
    cluster_name    = "nerdnam-dev"
    cluster_arn     = "arn:aws:eks:ap-northeast-2:082139775699:cluster/nerdnam-dev"
    route53_zone_id = "ZTESTONLY"
  }
  assert {
    condition     = aws_eks_pod_identity_association.controller["lbc"].namespace == "kube-system" && aws_eks_pod_identity_association.controller["lbc"].service_account == "aws-load-balancer-controller"
    error_message = "LBC chart와 Pod Identity service account가 일치해야 합니다."
  }
  assert {
    condition     = aws_eks_pod_identity_association.controller["cert_manager"].service_account == "cert-manager" && aws_eks_pod_identity_association.controller["external_secrets"].service_account == "external-secrets"
    error_message = "DNS/Secret controller 역할을 각 service account에 연결해야 합니다."
  }
  assert {
    condition     = toset(keys(aws_secretsmanager_secret.workload)) == toset(["backend", "data", "ai", "monitoring"]) && alltrue([for s in aws_secretsmanager_secret.workload : s.recovery_window_in_days == 7])
    error_message = "런타임 Secret 메타데이터와 복구 기간이 변경됐습니다."
  }
}
