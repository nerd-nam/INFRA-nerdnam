mock_provider "helm" {}
override_data {
  target = data.terraform_remote_state.aws
  values = {
    outputs = {
      eks = {
        cluster_name                       = "nerdnam-dev"
        cluster_endpoint                   = "https://example.invalid"
        cluster_certificate_authority_data = "dGVzdC1jYS1vbmx5"
        public_access_cidrs                = ["203.0.113.1/32"]
      }
      network = { vpc_id = "vpc-test", public_subnet_ids = ["subnet-test"], subnet_cidrs = { public = "10.20.0.0/24" } }
      platform = {
        route53_zone_id = "ZTESTONLY"
        secret_arns     = { backend = "test-backend-arn", data = "test-data-arn", ai = "test-ai-arn", monitoring = "test-monitoring-arn" }
      }
      observability = { loki_bucket = "test-loki-bucket", tempo_bucket = "test-tempo-bucket" }
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
    condition     = yamldecode(helm_release.seed.values[0]).environment.appHostname == "app.example.invalid" && yamldecode(helm_release.seed.values[0]).environment.lokiBucket == "test-loki-bucket" && yamldecode(helm_release.seed.values[0]).environment.tempoBucket == "test-tempo-bucket" && !can(yamldecode(helm_release.seed.values[0]).environment.images)
    error_message = "서비스 도메인은 bootstrap 입력, 이미지 digest 는 Git(gitops/apps/images.yaml)이 소유해야 합니다."
  }
  assert {
    condition = (
      yamldecode(helm_release.seed.values[0]).environment.adminAllowCidrs == ["203.0.113.1/32"] &&
      yamldecode(helm_release.seed.values[0]).environment.nlbSourceCidrs == ["10.20.0.0/24"] &&
      yamldecode(helm_release.seed.values[0]).environment.grafanaHostname == "grafana.app.example.invalid" &&
      yamldecode(helm_release.seed.values[0]).environment.argocdHostname == "argocd.app.example.invalid" &&
      yamldecode(helm_release.argocd.values[1]).configs.cm.url == "https://argocd.app.example.invalid"
    )
    error_message = "관리 도구 주소와 허용 IP 는 관리 IP 목록(EKS API 와 같은 값)에서 와야 합니다."
  }
  assert {
    condition     = yamldecode(helm_release.argocd.values[0]).server.service.type == "ClusterIP"
    error_message = "Argo CD 관리 UI를 공개하면 안 됩니다."
  }
}
