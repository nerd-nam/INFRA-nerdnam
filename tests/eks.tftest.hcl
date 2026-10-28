mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_eks_addon_version" {
    defaults = { version = "v1.0.0-eksbuild.1" }
  }
}

variables {
  name                = "nerdnam-dev"
  kubernetes_version  = "1.35"
  cluster_subnet_ids  = ["subnet-public", "subnet-private"]
  public_subnet_ids   = ["subnet-public"]
  private_subnet_ids  = ["subnet-private"]
  admin_principal_arn = "arn:aws:iam::082139775699:user/nerdnam-infra"
  public_access_cidrs = ["203.0.113.1/32"]
  instance_types      = { app = "m7i.xlarge", platform = "m7i.xlarge", data = "m7i.large" }
}

run "fixed_nodes_and_access" {
  command = plan
  module { source = "./modules/eks" }

  assert {
    condition = alltrue([for group in aws_eks_node_group.this :
      group.scaling_config[0].min_size == 1 && group.scaling_config[0].desired_size == 1 && group.scaling_config[0].max_size == 1
    ])
    error_message = "노드 그룹은 각각 1대로 고정해야 합니다."
  }
  assert {
    condition     = aws_eks_node_group.this["app"].subnet_ids == toset(["subnet-public"]) && aws_eks_node_group.this["data"].subnet_ids == toset(["subnet-private"])
    error_message = "역할별 서브넷 배치가 다릅니다."
  }
  assert {
    condition     = length(aws_eks_node_group.this["app"].taint) == 0 && length(aws_eks_node_group.this["data"].taint) == 1 && length(aws_eks_node_group.this["platform"].taint) == 1
    error_message = "전용 노드 taint 설정이 다릅니다."
  }
  assert {
    condition     = aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions == false && aws_eks_cluster.this.vpc_config[0].public_access_cidrs == toset(["203.0.113.1/32"])
    error_message = "EKS 접근 제한 설정이 다릅니다."
  }
  assert {
    condition     = alltrue([for attachment in aws_iam_role_policy_attachment.node : !endswith(attachment.policy_arn, "AmazonEKS_CNI_Policy")]) && one(aws_eks_addon.bootstrap["vpc-cni"].pod_identity_association).service_account == "aws-node"
    error_message = "CNI는 노드 역할 대신 aws-node 전용 Pod Identity를 사용해야 합니다."
  }
  assert {
    condition = (
      contains(jsondecode(aws_eks_addon.coredns.configuration_values).affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[1].values, "platform") &&
      !contains(jsondecode(aws_eks_addon.coredns.configuration_values).affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[1].values, "data") &&
      anytrue([for t in jsondecode(aws_eks_addon.coredns.configuration_values).tolerations : try(t.key == "dedicated" && t.value == "platform" && t.effect == "NoSchedule", false)])
    )
    error_message = "CoreDNS는 platform taint를 허용하고 data 노드를 제외해야 합니다."
  }
}

run "reject_unrestricted_api" {
  command = plan
  module { source = "./modules/eks" }
  variables {
    public_access_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [aws_eks_cluster.this]
}

run "reject_noncanonical_api_cidr" {
  command = plan
  module { source = "./modules/eks" }
  variables { public_access_cidrs = ["203.0.113.1/24"] }
  expect_failures = [aws_eks_cluster.this]
}

run "reject_session_principal" {
  command = plan
  module { source = "./modules/eks" }
  variables { admin_principal_arn = "arn:aws:sts::082139775699:assumed-role/admin/session" }
  expect_failures = [aws_eks_cluster.this]
}

run "reject_unknown_addon" {
  command = plan
  module { source = "./modules/eks" }
  variables { addon_versions = { typo = "v1.0.0-eksbuild.1" } }
  expect_failures = [var.addon_versions]
}
