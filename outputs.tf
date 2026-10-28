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
  description = "클러스터, 노드 그룹, ECR 및 add-on 정보."
  value       = module.eks
}

output "platform" {
  description = "GitOps controllers의 역할, Secret ARN, DNS zone. Secret 값은 포함하지 않는다."
  value       = module.platform
}

output "workload" {
  description = "AI Bedrock 역할과 이미지 CI 역할(GitHub OIDC). 앱 저장소 workflow 에 CI 역할 ARN 을 넣는다."
  value       = module.workload
}
