locals {
  node_groups = {
    app      = { instance_type = var.instance_types.app, subnet_ids = var.public_subnet_ids }
    platform = { instance_type = var.instance_types.platform, subnet_ids = var.private_subnet_ids }
    data     = { instance_type = var.instance_types.data, subnet_ids = var.private_subnet_ids }
  }
  addons = toset(["vpc-cni", "kube-proxy", "coredns", "eks-pod-identity-agent", "aws-ebs-csi-driver"])
}

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "pod_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}
resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}
resource "aws_eks_cluster" "this" {
  name                          = var.name
  role_arn                      = aws_iam_role.cluster.arn
  version                       = var.kubernetes_version
  bootstrap_self_managed_addons = false
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }
  vpc_config {
    subnet_ids              = var.cluster_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }
  lifecycle {
    precondition {
      condition     = can(regex("^arn:aws:iam::[0-9]{12}:(user|role)/.+$", var.admin_principal_arn))
      error_message = "EKS 관리자 IAM 사용자 또는 역할 ARN을 지정해야 합니다."
    }
    precondition {
      condition     = length(var.public_access_cidrs) > 0 && alltrue([for cidr in var.public_access_cidrs : try(cidrnetmask(cidr) != "0.0.0.0" && cidrsubnet(cidr, 0, 0) == cidr, false)])
      error_message = "EKS 공개 API 접근을 제한할 정규화된 IPv4 CIDR을 지정해야 합니다 (/0 불가)."
    }
  }
  depends_on = [aws_iam_role_policy_attachment.cluster]
}
resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.admin_principal_arn
  type          = "STANDARD"
}
resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
}
resource "aws_iam_role" "node" {
  name               = "${var.name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    # Bootstrap용: CNI를 별도 역할로 옮긴 뒤 제거한다.
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}
resource "aws_iam_role" "ebs_csi" {
  name               = "${var.name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_assume.json
}
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

data "aws_eks_addon_version" "compatible" {
  for_each           = local.addons
  addon_name         = each.value
  kubernetes_version = var.kubernetes_version
  most_recent        = false
}

resource "aws_eks_addon" "bootstrap" {
  for_each                    = toset(["vpc-cni", "kube-proxy", "eks-pod-identity-agent"])
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  addon_version               = lookup(var.addon_versions, each.value, data.aws_eks_addon_version.compatible[each.value].version)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
}

resource "aws_launch_template" "node" {
  for_each = local.node_groups
  name     = "${var.name}-${each.key}"
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
}
resource "aws_eks_node_group" "this" {
  for_each        = local.node_groups
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = each.value.subnet_ids
  instance_types  = [each.value.instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  labels          = { workload = each.key }
  scaling_config {
    min_size     = 1
    desired_size = 1
    max_size     = 1
  }
  dynamic "taint" {
    for_each = each.key == "app" ? [] : [each.key]
    content {
      key    = "dedicated"
      value  = taint.value
      effect = "NO_SCHEDULE"
    }
  }
  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = tostring(aws_launch_template.node[each.key].latest_version)
  }
  update_config { max_unavailable = 1 }
  depends_on = [aws_iam_role_policy_attachment.node, aws_eks_addon.bootstrap]
}
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  addon_version               = lookup(var.addon_versions, "coredns", data.aws_eks_addon_version.compatible["coredns"].version)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  depends_on                  = [aws_eks_node_group.this]
}
resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = lookup(var.addon_versions, "aws-ebs-csi-driver", data.aws_eks_addon_version.compatible["aws-ebs-csi-driver"].version)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }
  depends_on = [aws_eks_node_group.this, aws_iam_role_policy_attachment.ebs_csi]
}
resource "aws_ecr_repository" "apps" {
  for_each             = toset(["web", "api", "ai"])
  name                 = "${var.name}/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}
