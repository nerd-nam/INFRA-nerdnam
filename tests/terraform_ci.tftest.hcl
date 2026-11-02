# GitHub Actions Terraform 역할: plan 은 PR·main 에서 읽기 전용, apply 는 승인 Environment 에서만. AWS 를 호출하지 않는다.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name              = "nerdnam-dev"
  account_id        = "082139775699"
  oidc_provider_arn = "arn:aws:iam::082139775699:oidc-provider/token.actions.githubusercontent.com"
  state_bucket      = "nerdnam-terraform-082139775699-ap-northeast-2-an"
  state_key         = "dev/terraform.tfstate"
}

run "roles_are_split_by_trust" {
  command = apply
  module { source = "./modules/terraform_ci" }

  assert {
    condition = toset(one([for c in data.aws_iam_policy_document.trust["plan"].statement[0].condition : c.values
      if c.variable == "token.actions.githubusercontent.com:sub"])) == toset([
      "repo:nerd-nam@345653190/INFRA-nerdnam@1434016713:pull_request",
      "repo:nerd-nam@345653190/INFRA-nerdnam@1434016713:ref:refs/heads/main",
    ])
    error_message = "plan 역할은 이 저장소의 PR 과 main 에서만 받을 수 있어야 합니다."
  }
  assert {
    condition = toset(one([for c in data.aws_iam_policy_document.trust["apply"].statement[0].condition : c.values
    if c.variable == "token.actions.githubusercontent.com:sub"])) == toset(["repo:nerd-nam@345653190/INFRA-nerdnam@1434016713:environment:dev-infra"])
    error_message = "apply 역할은 사람 승인 Environment(dev-infra) 작업에서만 받을 수 있어야 합니다(브랜치·PR 이 아니라)."
  }
  assert {
    condition     = aws_iam_role_policy_attachment.plan_read_only.policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess" && length(aws_iam_role_policy_attachment.apply) == 7
    error_message = "plan 은 ReadOnlyAccess 만, apply 는 실행자 정책 7개를 받아야 합니다."
  }
  assert {
    condition     = !contains(keys(aws_iam_role_policy_attachment.apply), "NerdnamTerraformBootstrapStateDev")
    error_message = "CI 는 bootstrap 을 돌리지 않으므로 bootstrap state 정책을 받지 않습니다."
  }
  assert {
    condition = one([for s in data.aws_iam_policy_document.plan_deny_data.statement : s.not_resources
    if s.sid == "DenyObjectReadExceptState"]) == toset(["arn:aws:s3:::nerdnam-terraform-082139775699-ap-northeast-2-an/dev/terraform.tfstate"])
    error_message = "plan 역할은 state 객체 말고는 S3 객체를 읽으면 안 됩니다(공개 로그로 새지 않게)."
  }
}

run "reject_mutable_repository_subject" {
  command = plan
  module { source = "./modules/terraform_ci" }
  variables { repository = "nerd-nam/INFRA-nerdnam" }
  expect_failures = [var.repository]
}
