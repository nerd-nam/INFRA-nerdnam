variable "name" { type = string }
variable "account_id" { type = string }
variable "oidc_provider_arn" { type = string }

variable "repository" {
  description = "INFRA 저장소의 OIDC sub 앞부분(repo: 뒤). immutable subject(owner@ID/name@ID). 확인: gh api repos/<owner>/<name>/actions/oidc/customization/sub"
  type        = string
  default     = "nerd-nam@345653190/INFRA-nerdnam@1434016713"
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+@[0-9]+/[A-Za-z0-9_.-]+@[0-9]+$", var.repository))
    error_message = "owner@ID/name@ID 형식(GitHub immutable subject)이 필요합니다."
  }
}

variable "apply_environment" {
  description = "apply 역할을 받을 수 있는 GitHub Environment. 저장소 설정에서 Required reviewers(사람 승인)와 main 브랜치 제한을 건다."
  type        = string
  default     = "dev-infra"
}

variable "state_bucket" { type = string }
variable "state_key" { type = string }

variable "apply_policy_names" {
  description = "apply 역할에 붙일 고객 관리형 정책(iam/README.md). Terraform root 실행자 nerdnam-infra 와 같은 묶음. bootstrap state 정책은 넣지 않는다(CI 는 bootstrap 을 돌리지 않는다)."
  type        = list(string)
  default = [
    "NerdnamTerraformStateDev",
    "NerdnamTerraformNetworkDev",
    "NerdnamTerraformEksDev",
    "NerdnamTerraformPlatformDev",
    "NerdnamTerraformWorkloadDev",
    "NerdnamTerraformObservabilityDev",
    "NerdnamTerraformCiDev",
  ]
}
