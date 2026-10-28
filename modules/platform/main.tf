locals {
  controllers = {
    lbc              = { namespace = "kube-system", service_account = "aws-load-balancer-controller" }
    cert_manager     = { namespace = "cert-manager", service_account = "cert-manager" }
    external_secrets = { namespace = "external-secrets", service_account = "external-secrets" }
  }
}

data "aws_iam_policy_document" "trust" {
  for_each = local.controllers
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
      values   = [each.value.namespace]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [each.value.service_account]
    }
  }
}
resource "aws_iam_role" "controller" {
  for_each           = local.controllers
  name               = "${var.cluster_name}-${replace(each.key, "_", "-")}"
  assume_role_policy = data.aws_iam_policy_document.trust[each.key].json
}
resource "aws_eks_pod_identity_association" "controller" {
  for_each        = local.controllers
  cluster_name    = var.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.controller[each.key].arn
  depends_on      = [aws_iam_role_policy.lbc, aws_iam_role_policy.cert_manager, aws_iam_role_policy.external_secrets]
}
resource "aws_iam_role_policy" "lbc" {
  name   = "load-balancer-controller"
  role   = aws_iam_role.controller["lbc"].id
  policy = file("${path.module}/lbc-iam-policy.json")
}
data "aws_iam_policy_document" "cert_manager" {
  statement {
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }
  statement {
    actions   = ["route53:ListResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.route53_zone_id}"]
  }
  statement {
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.route53_zone_id}"]
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["TXT"]
    }
  }
}
resource "aws_iam_role_policy" "cert_manager" {
  name   = "dns01"
  role   = aws_iam_role.controller["cert_manager"].id
  policy = data.aws_iam_policy_document.cert_manager.json
}
resource "aws_secretsmanager_secret" "workload" {
  for_each                = toset(["backend", "data", "ai"])
  name                    = "nerdnam/dev/${each.value}"
  description             = "${each.value} runtime JSON; values supplied outside Terraform"
  recovery_window_in_days = 7
}
data "aws_iam_policy_document" "external_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [for secret in aws_secretsmanager_secret.workload : secret.arn]
  }
}
resource "aws_iam_role_policy" "external_secrets" {
  name   = "read-workload-secrets"
  role   = aws_iam_role.controller["external_secrets"].id
  policy = data.aws_iam_policy_document.external_secrets.json
}
