variable "git_revision" {
  description = <<-EOT
    Argo CD 가 추적할 INFRA 저장소 revision. 기본은 main 브랜치: PR merge 로 "무엇을", 수동 sync 로 "언제" 배포할지 정한다.
    commit SHA·tag 는 장애 때 특정 지점에 잠시 고정할 때만 쓰고, 끝나면 main 으로 되돌린다.
  EOT
  type        = string
  default     = "main"
}
variable "sample_hostname" {
  description = "HTTPS 샘플 서비스의 실제 DNS 이름."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}$", var.sample_hostname))
    error_message = "sample_hostname에는 URL이 아닌 DNS 이름을 넣으세요."
  }
}
variable "app_hostname" {
  description = "서비스 웹 주소(FE·BE 공용 HTTPS 도메인). OAuth 콜백 https://<이 값>/login/oauth2/code/{google,kakao} 를 각 콘솔에 등록한다."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}$", var.app_hostname))
    error_message = "app_hostname에는 URL이 아닌 DNS 이름을 넣으세요."
  }
}
variable "acme_email" { type = string }
variable "acme_server" {
  type    = string
  default = "https://acme-v02.api.letsencrypt.org/directory"
}
