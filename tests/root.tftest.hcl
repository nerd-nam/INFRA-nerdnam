mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "082139775699" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

run "network_and_eks_are_always_planned" {
  command = plan
  variables {
    eks_admin_principal_arn = "arn:aws:iam::082139775699:user/nerdnam-infra"
    eks_public_access_cidrs = ["203.0.113.1/32"]
    # 테스트 전용 버전. 실제 AWS 배포용이 아니다.
    eks_addon_versions = {
      vpc-cni                = "v1.0.1-eksbuild.1"
      kube-proxy             = "v1.0.2-eksbuild.1"
      coredns                = "v1.0.3-eksbuild.1"
      eks-pod-identity-agent = "v1.0.4-eksbuild.1"
      aws-ebs-csi-driver     = "v1.0.5-eksbuild.1"
    }
  }
  assert {
    condition     = output.eks.cluster_name == "nerdnam-dev" && output.eks.node_group_names == { app = "app", platform = "platform", data = "data" }
    error_message = "별도 활성화 스위치 없이 EKS와 세 노드 그룹이 포함되어야 합니다."
  }
  assert {
    condition     = tomap(output.eks.addon_versions) == var.eks_addon_versions
    error_message = "명시한 add-on 버전을 기본 버전으로 덮어쓰면 안 됩니다."
  }
  assert {
    condition     = output.network.vpc_cidr == "10.20.0.0/16"
    error_message = "EKS와 함께 기존 VPC 구성도 유지되어야 합니다."
  }
}
