# 앱 워크로드의 AWS 권한: AI Pod 의 Bedrock 호출, GitHub Actions 의 ECR push.
# Kubernetes 객체(ServiceAccount 등)는 Argo(gitops/apps)가 소유한다. 여기서는 IAM 과 Pod Identity 연결만 만든다.

locals {
  llm_model_id = trimprefix(var.llm_inference_profile_id, "global.")
  llm_profile  = "arn:aws:bedrock:${var.region}:${var.account_id}:inference-profile/${var.llm_inference_profile_id}"
  ai_service   = { namespace = "nerdnam", service_account = "ai" }
}

# ---------------------------------------------------------------- AI → Bedrock
data "aws_iam_policy_document" "ai_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [var.cluster_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [local.ai_service.namespace]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [local.ai_service.service_account]
    }
  }
}

# AI 서버는 bedrock-runtime 의 Converse(LLM)·InvokeModel(임베딩)만 쓴다. 둘 다 bedrock:InvokeModel 권한이다.
# Global 프로필은 AWS 문서의 3단 구성(요청 리전 프로필, 요청 리전 모델, 리전 없는 global 모델)이 모두 필요하다.
data "aws_iam_policy_document" "bedrock" {
  statement {
    sid       = "EmbeddingInRegion"
    actions   = ["bedrock:InvokeModel"]
    resources = ["arn:aws:bedrock:${var.region}::foundation-model/${var.embedding_model_id}"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }
  statement {
    sid       = "LlmGlobalProfile"
    actions   = ["bedrock:InvokeModel"]
    resources = [local.llm_profile]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }
  statement {
    sid       = "LlmModelInRequestRegion"
    actions   = ["bedrock:InvokeModel"]
    resources = ["arn:aws:bedrock:${var.region}::foundation-model/${local.llm_model_id}"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
    condition {
      test     = "StringEquals"
      variable = "bedrock:InferenceProfileArn"
      values   = [local.llm_profile]
    }
  }
  statement {
    sid       = "LlmModelGlobalRouting"
    actions   = ["bedrock:InvokeModel"]
    resources = ["arn:aws:bedrock:::foundation-model/${local.llm_model_id}"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["unspecified"]
    }
    condition {
      test     = "StringEquals"
      variable = "bedrock:InferenceProfileArn"
      values   = [local.llm_profile]
    }
  }
}

resource "aws_iam_role" "ai" {
  name               = "${var.name}-ai"
  assume_role_policy = data.aws_iam_policy_document.ai_trust.json
}
resource "aws_iam_role_policy" "ai_bedrock" {
  name   = "bedrock-invoke"
  role   = aws_iam_role.ai.id
  policy = data.aws_iam_policy_document.bedrock.json
}
resource "aws_eks_pod_identity_association" "ai" {
  cluster_name    = var.cluster_name
  namespace       = local.ai_service.namespace
  service_account = local.ai_service.service_account
  role_arn        = aws_iam_role.ai.arn
  depends_on      = [aws_iam_role_policy.ai_bedrock]
}

# ---------------------------------------------------------------- GitHub Actions → ECR
# 계정에 같은 URL 의 provider 가 이미 있으면 생성이 실패한다. 그때는 import 해서 이 state 가 소유하게 한다.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "ci_trust" {
  for_each = var.github_repositories
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${each.value}:ref:refs/heads/${var.ci_branch}"]
    }
  }
}

data "aws_iam_policy_document" "ci_push" {
  for_each = var.ecr_repository_arns
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "PushOwnRepository"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [each.value]
  }
}

resource "aws_iam_role" "ci" {
  for_each             = var.github_repositories
  name                 = "${var.name}-ci-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.ci_trust[each.key].json
  max_session_duration = 3600
}
resource "aws_iam_role_policy" "ci_push" {
  for_each = var.github_repositories
  name     = "ecr-push"
  role     = aws_iam_role.ci[each.key].id
  policy   = data.aws_iam_policy_document.ci_push[each.key].json
}
