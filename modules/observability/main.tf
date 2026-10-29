# 7·8단계 관측 저장소: Loki(로그)와 Tempo(trace)가 각자 쓰는 S3 bucket 과 Pod Identity 역할.
# 둘은 bucket·역할을 나눈다. 한쪽 권한이 다른 쪽 데이터에 닿지 않게 한다.
# 보존은 Loki compactor·Tempo backend worker 가 먼저 지운다. lifecycle 은 그보다 길게(4배) 둬서 앱이 지우기 전에
# 사라지지 않게 하고, 앱의 삭제가 멈춰도 bucket 이 끝없이 커지지 않게 막는 안전망이다.

locals {
  stores = {
    loki  = { service_account = "loki", retention_days = var.log_retention_days }
    tempo = { service_account = "tempo", retention_days = var.trace_retention_days }
  }
  namespace = "monitoring"
}

resource "aws_s3_bucket" "store" {
  for_each = local.stores
  bucket   = "${var.name}-${each.key}-${var.account_id}-${var.region}"
}
resource "aws_s3_bucket_public_access_block" "store" {
  for_each                = local.stores
  bucket                  = aws_s3_bucket.store[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_ownership_controls" "store" {
  for_each = local.stores
  bucket   = aws_s3_bucket.store[each.key].id
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "store" {
  for_each = local.stores
  bucket   = aws_s3_bucket.store[each.key].id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_lifecycle_configuration" "store" {
  for_each = local.stores
  bucket   = aws_s3_bucket.store[each.key].id
  rule {
    id     = "expire-after-${each.key}-retention"
    status = "Enabled"
    filter {}
    expiration { days = each.value.retention_days * 4 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}
data "aws_iam_policy_document" "bucket" {
  for_each = local.stores
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    resources = [aws_s3_bucket.store[each.key].arn, "${aws_s3_bucket.store[each.key].arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}
resource "aws_s3_bucket_policy" "store" {
  for_each   = local.stores
  bucket     = aws_s3_bucket.store[each.key].id
  policy     = data.aws_iam_policy_document.bucket[each.key].json
  depends_on = [aws_s3_bucket_public_access_block.store]
}

data "aws_iam_policy_document" "trust" {
  for_each = local.stores
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
      values   = [local.namespace]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [each.value.service_account]
    }
  }
}
data "aws_iam_policy_document" "s3" {
  for_each = local.stores
  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.store[each.key].arn]
  }
  statement {
    sid       = "ReadWriteObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.store[each.key].arn}/*"]
  }
}
resource "aws_iam_role" "store" {
  for_each           = local.stores
  name               = "${var.name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.trust[each.key].json
}
resource "aws_iam_role_policy" "store" {
  for_each = local.stores
  name     = "${each.key}-bucket"
  role     = aws_iam_role.store[each.key].id
  policy   = data.aws_iam_policy_document.s3[each.key].json
}
resource "aws_eks_pod_identity_association" "store" {
  for_each        = local.stores
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.store[each.key].arn
  depends_on      = [aws_iam_role_policy.store]
}
