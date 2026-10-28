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
  description = "EKS add-on별 AWS 호환 버전. 빈 맵이면 AWS 기본 호환 버전을 조회한다."
  type        = map(string)
  default     = {}
}
