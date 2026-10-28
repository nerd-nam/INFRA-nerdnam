variable "git_revision" {
  description = "GitOps 코드가 있는 Git commit SHA 또는 관리할 branch/tag."
  type        = string
}
variable "sample_hostname" {
  description = "HTTPS 샘플 서비스의 실제 DNS 이름."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}$", var.sample_hostname))
    error_message = "sample_hostname에는 URL이 아닌 DNS 이름을 넣으세요."
  }
}
variable "acme_email" { type = string }
variable "acme_server" {
  type    = string
  default = "https://acme-v02.api.letsencrypt.org/directory"
}
