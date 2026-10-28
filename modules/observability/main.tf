# 7단계 로그 저장소: Loki(monitoring/loki ServiceAccount)가 쓰는 S3 bucket 과 Pod Identity 역할.
# 보존은 Loki compactor 가 먼저 지운다(7일). lifecycle 은 그보다 길게 둬서 Loki 가 지우기 전에 사라지지 않게 하고,
# compactor 가 멈춰도 bucket 이 끝없이 커지지 않게 막는 안전망이다.

locals {
  loki_bucket  = "${var.name}-loki-${var.account_id}-${var.region}"
  loki_service = { namespace = "monitoring", service_account = "loki" }
}

resource "aws_s3_bucket" "loki" {
  bucket = local.loki_bucket
}
resource "aws_s3_bucket_public_access_block" "loki" {
  bucket                  = aws_s3_bucket.loki.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_ownership_controls" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    id     = "expire-after-loki-retention"
    status = "Enabled"
    filter {}
    expiration { days = var.log_retention_days * 4 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}
data "aws_iam_policy_document" "loki_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    resources = [aws_s3_bucket.loki.arn, "${aws_s3_bucket.loki.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}
resource "aws_s3_bucket_policy" "loki" {
  bucket     = aws_s3_bucket.loki.id
  policy     = data.aws_iam_policy_document.loki_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.loki]
}

data "aws_iam_policy_document" "loki_trust" {
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
      values   = [local.loki_service.namespace]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [local.loki_service.service_account]
    }
  }
}
data "aws_iam_policy_document" "loki_s3" {
  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.loki.arn]
  }
  statement {
    sid       = "ReadWriteObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.loki.arn}/*"]
  }
}
resource "aws_iam_role" "loki" {
  name               = "${var.name}-loki"
  assume_role_policy = data.aws_iam_policy_document.loki_trust.json
}
resource "aws_iam_role_policy" "loki" {
  name   = "loki-bucket"
  role   = aws_iam_role.loki.id
  policy = data.aws_iam_policy_document.loki_s3.json
}
resource "aws_eks_pod_identity_association" "loki" {
  cluster_name    = var.cluster_name
  namespace       = local.loki_service.namespace
  service_account = local.loki_service.service_account
  role_arn        = aws_iam_role.loki.arn
  depends_on      = [aws_iam_role_policy.loki]
}
