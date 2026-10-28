mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::082139775699:oidc-provider/token.actions.githubusercontent.com" }
  }
}

variables {
  name         = "nerdnam-dev"
  region       = "ap-northeast-2"
  account_id   = "082139775699"
  cluster_name = "nerdnam-dev"
  cluster_arn  = "arn:aws:eks:ap-northeast-2:082139775699:cluster/nerdnam-dev"
  ecr_repository_arns = {
    web = "arn:aws:ecr:ap-northeast-2:082139775699:repository/nerdnam-dev/web"
    api = "arn:aws:ecr:ap-northeast-2:082139775699:repository/nerdnam-dev/api"
    ai  = "arn:aws:ecr:ap-northeast-2:082139775699:repository/nerdnam-dev/ai"
  }
}

run "ai_bedrock_identity" {
  command = plan
  module { source = "./modules/workload" }

  assert {
    condition     = aws_eks_pod_identity_association.ai.namespace == "nerdnam" && aws_eks_pod_identity_association.ai.service_account == "ai"
    error_message = "AI 역할은 gitops/apps 의 nerdnam/ai ServiceAccount 에만 연결해야 합니다."
  }
  assert {
    condition = toset(flatten([for s in data.aws_iam_policy_document.bedrock.statement : s.resources])) == toset([
      "arn:aws:bedrock:ap-northeast-2::foundation-model/amazon.titan-embed-text-v2:0",
      "arn:aws:bedrock:ap-northeast-2:082139775699:inference-profile/global.amazon.nova-2-lite-v1:0",
      "arn:aws:bedrock:ap-northeast-2::foundation-model/amazon.nova-2-lite-v1:0",
      "arn:aws:bedrock:::foundation-model/amazon.nova-2-lite-v1:0",
    ])
    error_message = "Bedrock 권한은 Titan 임베딩과 Nova 2 Lite Global 프로필 3단 구성으로 한정해야 합니다."
  }
  assert {
    condition     = toset(flatten([for s in data.aws_iam_policy_document.bedrock.statement : s.actions])) == toset(["bedrock:InvokeModel"])
    error_message = "AI 는 InvokeModel(Converse 포함)만 필요합니다."
  }
  assert {
    condition = alltrue([for s in data.aws_iam_policy_document.bedrock.statement :
      anytrue([for c in s.condition : c.variable == "bedrock:InferenceProfileArn"]) if strcontains(join(",", s.resources), "nova")
    && !strcontains(join(",", s.resources), "inference-profile")])
    error_message = "Nova foundation-model 권한은 Global 프로필을 거친 호출로만 제한해야 합니다."
  }
}

run "ci_push_is_scoped_per_repository" {
  command = plan
  module { source = "./modules/workload" }

  assert {
    condition     = toset(keys(aws_iam_role.ci)) == toset(["web", "api", "ai"])
    error_message = "이미지별 CI 역할이 필요합니다."
  }
  assert {
    condition = alltrue([for k, doc in data.aws_iam_policy_document.ci_trust :
      toset(one([for c in doc.statement[0].condition : c.values if c.variable == "token.actions.githubusercontent.com:sub"])) == toset([
        "repo:${var.github_repositories[k]}:ref:refs/heads/main"
    ])])
    error_message = "CI 역할은 해당 저장소의 main 브랜치 workflow 만 받을 수 있어야 합니다."
  }
  assert {
    condition = alltrue([for k, doc in data.aws_iam_policy_document.ci_push :
    toset(doc.statement[1].resources) == toset([var.ecr_repository_arns[k]]) && !contains(doc.statement[1].actions, "ecr:DeleteRepository")])
    error_message = "각 CI 역할은 자기 ECR repository 에만 push 해야 합니다."
  }
}

run "rejects_non_global_llm_profile" {
  command = plan
  module { source = "./modules/workload" }
  variables {
    llm_inference_profile_id = "amazon.nova-2-lite-v1:0"
  }
  expect_failures = [var.llm_inference_profile_id]
}
