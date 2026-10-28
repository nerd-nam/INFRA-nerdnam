variable "vpc_cidr" {
  description = "서울 dev VPC의 정규화된 IPv4 /16 CIDR. 기존 연결망과 겹치지 않아야 한다."
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zones" {
  description = "public에는 app/NLB/NAT, private에는 platform/data를 배치한다."
  type = object({
    public  = string
    private = string
  })
  default = {
    public  = "ap-northeast-2a"
    private = "ap-northeast-2c"
  }
}

variable "eks_kubernetes_version" {
  type    = string
  default = "1.35"
}
variable "eks_admin_principal_arn" {
  description = "EKS 관리자 IAM 사용자 또는 역할 ARN."
  type        = string
}
variable "eks_public_access_cidrs" {
  description = "관리자가 접속할 고정 공인 IPv4 CIDR 목록."
  type        = list(string)
}
variable "eks_instance_types" {
  type    = object({ app = string, platform = string, data = string })
  default = { app = "m7i.xlarge", platform = "m7i.xlarge", data = "m7i.large" }
}
variable "eks_addon_versions" {
  description = "add-on 호환 버전 고정값. 비어 있으면 AWS 기본 버전을 조회한다."
  type        = map(string)
  default     = {}
}
