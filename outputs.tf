output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "bootstrap_message" {
  value = terraform_data.bootstrap_test.output
}

output "network" {
  description = "다음 EKS 단계에서 사용할 VPC·서브넷·라우팅 식별자."
  value       = module.network
}

output "eks" {
  description = "EKS 활성화 시 클러스터, 노드 그룹, ECR 및 add-on 정보."
  value       = try(module.eks[0], null)
}
