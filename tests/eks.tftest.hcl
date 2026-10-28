mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_eks_addon_version" {
    defaults = { version = "v1.0.0-eksbuild.1" }
  }
}

run "fixed_nodes_and_access" {
  command = plan
  module { source = "./modules/eks" }
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
}

run "reject_unrestricted_api" {
  command = plan
  module { source = "./modules/eks" }
  variables {
    name                = "nerdnam-dev"
    kubernetes_version  = "1.35"
    cluster_subnet_ids  = ["subnet-public", "subnet-private"]
    public_subnet_ids   = ["subnet-public"]
    private_subnet_ids  = ["subnet-private"]
    admin_principal_arn = "arn:aws:iam::082139775699:user/nerdnam-infra"
    public_access_cidrs = ["0.0.0.0/0"]
    instance_types      = { app = "m7i.xlarge", platform = "m7i.xlarge", data = "m7i.large" }
  }
  expect_failures = [aws_eks_cluster.this]
}
