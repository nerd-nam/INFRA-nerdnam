variable "name" { type = string }
variable "kubernetes_version" { type = string }
variable "cluster_subnet_ids" { type = list(string) }
variable "public_subnet_ids" { type = list(string) }
variable "private_subnet_ids" { type = list(string) }
variable "admin_principal_arn" { type = string }
variable "public_access_cidrs" { type = list(string) }
variable "instance_types" {
  type = object({ app = string, platform = string, data = string })
}
variable "addon_versions" {
  description = "EKS add-on별 고정 버전. 지정하지 않은 add-on만 plan 시 AWS 기본 호환 버전을 조회한다."
  type        = map(string)
  default     = {}
  validation {
    condition = alltrue([for name, version in var.addon_versions :
      contains(["vpc-cni", "kube-proxy", "coredns", "eks-pod-identity-agent", "aws-ebs-csi-driver"], name) && can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", version))
    ])
    error_message = "지원하는 add-on 이름과 v1.2.3-eksbuild.1 형식의 버전을 지정해야 합니다."
  }
}
