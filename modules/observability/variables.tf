variable "name" { type = string }
variable "region" { type = string }
variable "account_id" { type = string }
variable "cluster_name" { type = string }
variable "cluster_arn" { type = string }

variable "log_retention_days" {
  description = "Loki 가 지우는 기간(limits_config.retention_period)과 같은 일수. bucket lifecycle 은 이보다 길게 둔다."
  type        = number
  default     = 7
}

variable "trace_retention_days" {
  description = "Tempo 가 지우는 기간(tempo.retention)과 같은 일수. bucket lifecycle 은 이보다 길게 둔다."
  type        = number
  default     = 3
}
