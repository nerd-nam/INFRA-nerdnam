mock_provider "helm" {}
override_data {
  target = data.terraform_remote_state.aws
  values = {
    outputs = {
      eks = {
        cluster_name                       = "nerdnam-dev"
        cluster_endpoint                   = "https://example.invalid"
        cluster_certificate_authority_data = "dGVzdC1jYS1vbmx5"
      }
      network = { vpc_id = "vpc-test", public_subnet_ids = ["subnet-test"] }
      platform = {
        route53_zone_id = "ZTESTONLY"
        secret_arns     = { backend = "test-backend-arn", data = "test-data-arn", ai = "test-ai-arn", monitoring = "test-monitoring-arn" }
      }
      observability = { loki_bucket = "test-loki-bucket" }
    }
  }
}
run "bootstrap_uses_aws_outputs" {
  command = plan
  variables {
    git_revision    = "test-fixture-only"
    sample_hostname = "sample.example.invalid"
    app_hostname    = "app.example.invalid"
    acme_email      = "test@example.invalid"
  }
  assert {
    condition     = yamldecode(helm_release.seed.values[0]).environment.vpcId == "vpc-test" && yamldecode(helm_release.seed.values[0]).environment.secretArns.data == "test-data-arn"
    error_message = "AWS output 식별자를 GitOps에 전달해야 합니다."
  }
  assert {
    condition     = yamldecode(helm_release.seed.values[0]).environment.appHostname == "app.example.invalid" && yamldecode(helm_release.seed.values[0]).environment.lokiBucket == "test-loki-bucket" && !can(yamldecode(helm_release.seed.values[0]).environment.images)
    error_message = "서비스 도메인은 bootstrap 입력, 이미지 digest 는 Git(gitops/apps/images.yaml)이 소유해야 합니다."
  }
  assert {
    condition     = yamldecode(helm_release.argocd.values[0]).server.service.type == "ClusterIP"
    error_message = "Argo CD 관리 UI를 공개하면 안 됩니다."
  }
}
