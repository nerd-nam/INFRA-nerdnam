variable "name" { type = string }
variable "region" { type = string }
variable "account_id" { type = string }
variable "cluster_name" { type = string }
variable "cluster_arn" { type = string }

variable "ecr_repository_arns" {
  description = "web/api/ai ECR repository ARN. 각 CI 역할은 자기 repository 에만 push 한다."
  type        = map(string)
  validation {
    condition     = toset(keys(var.ecr_repository_arns)) == toset(["web", "api", "ai"])
    error_message = "web, api, ai ECR repository ARN이 모두 필요합니다."
  }
}

variable "github_repositories" {
  description = <<-EOT
    이미지별 GitHub 저장소. OIDC 토큰의 sub 앞부분 그대로(repo: 뒤)이며 trust 의 sub 조건이 된다.
    nerd-nam 저장소는 GitHub 의 immutable subject(owner@ID/name@ID)를 쓴다. 저장소를 지우고 같은 이름으로
    다시 만들어도 ID 가 달라 역할을 받을 수 없다. 확인:
      gh api repos/<owner>/<name>/actions/oidc/customization/sub --jq .sub_claim_prefix
  EOT
  type        = map(string)
  default = {
    web = "nerd-nam@345653190/FE-nerdnam@1427904148"
    api = "nerd-nam@345653190/BE-nerdnam@1427904375"
    ai  = "nerd-nam@345653190/AI-nerdnam@1427905046"
  }
  validation {
    condition     = toset(keys(var.github_repositories)) == toset(["web", "api", "ai"]) && alltrue([for r in values(var.github_repositories) : can(regex("^[A-Za-z0-9_.-]+@[0-9]+/[A-Za-z0-9_.-]+@[0-9]+$", r))])
    error_message = "web, api, ai 각각 owner@ID/name@ID 형식(GitHub immutable subject)이 필요합니다."
  }
}

variable "ci_branch" {
  description = "ECR push 를 허용할 브랜치. PR·다른 브랜치 workflow 는 역할을 받을 수 없다."
  type        = string
  default     = "main"
}

# ADR-0007 에서 정한 모델. 바꾸면 AI 서버 설정(LLM_MODEL·EMBED_MODEL_ID)과 함께 바꾼다.
variable "llm_inference_profile_id" {
  type    = string
  default = "global.amazon.nova-2-lite-v1:0"
  validation {
    condition     = startswith(var.llm_inference_profile_id, "global.")
    error_message = "Global 교차 리전 추론 프로필 ID(global.*)를 지정하세요."
  }
}
variable "embedding_model_id" {
  type    = string
  default = "amazon.titan-embed-text-v2:0"
}
