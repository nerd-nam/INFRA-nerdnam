# GitHub Actions 에서 Terraform root 를 실행하는 역할 2개 (docs/Terraform-CI.md).
#
#   plan  : PR 과 main 의 plan. 읽기 전용(ReadOnlyAccess)에 데이터 읽기 차단을 더한다.
#           공개 저장소라 로그는 누구나 본다. PR 작업이 이 역할로 로그·객체를 읽어 출력하지 못하게 한다.
#   apply : 사람 승인 Environment 의 작업만 받을 수 있다. 권한은 Terraform 실행자(nerdnam-infra)와 같다.
#
# bootstrap(Argo CD) 은 EKS API 가 관리 IP 에서만 열려 있어 CI 에서 돌리지 않는다(로컬 scripts/tf-apply.sh).

locals {
  sub_prefix = "repo:${var.repository}"
  # plan 은 PR 과 main(merge 뒤 승인 전 plan)에서만. apply 는 승인 Environment 에서만.
  plan_subjects  = ["${local.sub_prefix}:pull_request", "${local.sub_prefix}:ref:refs/heads/main"]
  apply_subjects = ["${local.sub_prefix}:environment:${var.apply_environment}"]
  apply_policy_arns = {
    for name in var.apply_policy_names : name => "arn:aws:iam::${var.account_id}:policy/${name}"
  }
}

data "aws_iam_policy_document" "trust" {
  for_each = { plan = local.plan_subjects, apply = local.apply_subjects }
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

resource "aws_iam_role" "this" {
  for_each             = data.aws_iam_policy_document.trust
  name                 = "${var.name}-tf-${each.key}"
  assume_role_policy   = each.value.json
  max_session_duration = 3600
}

# ---------------------------------------------------------------- plan: 읽기 전용
resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.this["plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess 는 설정뿐 아니라 데이터도 읽는다(S3 객체·로그·이미지 등). plan 에는 설정과 state 만 필요하다.
data "aws_iam_policy_document" "plan_deny_data" {
  statement {
    sid           = "DenyObjectReadExceptState"
    effect        = "Deny"
    actions       = ["s3:GetObject", "s3:GetObjectVersion", "s3:GetObjectAttributes", "s3:GetObjectTorrent"]
    not_resources = ["arn:aws:s3:::${var.state_bucket}/${var.state_key}"]
  }
  statement {
    sid    = "DenyDataReads"
    effect = "Deny"
    actions = [
      "logs:GetLogEvents", "logs:FilterLogEvents", "logs:StartQuery", "logs:GetQueryResults", "logs:StartLiveTail", "logs:GetLogRecord",
      "ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory",
      "secretsmanager:GetSecretValue", "kms:Decrypt",
      "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage",
      "dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query", "dynamodb:Scan",
      "ec2:GetConsoleOutput", "ec2:GetConsoleScreenshot", "lambda:GetFunction",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "plan_deny_data" {
  name   = "deny-data-reads"
  role   = aws_iam_role.this["plan"].id
  policy = data.aws_iam_policy_document.plan_deny_data.json
}

# ---------------------------------------------------------------- apply: 실행자와 같은 권한
resource "aws_iam_role_policy_attachment" "apply" {
  for_each   = local.apply_policy_arns
  role       = aws_iam_role.this["apply"].name
  policy_arn = each.value
}
