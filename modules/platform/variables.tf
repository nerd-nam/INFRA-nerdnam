variable "cluster_name" { type = string }
variable "cluster_arn" { type = string }
variable "route53_zone_id" {
  type = string
  validation {
    condition     = can(regex("^Z[A-Z0-9]+$", var.route53_zone_id))
    error_message = "Route53 hosted zone ID를 지정하세요 (/hostedzone/ 접두어 제외)."
  }
}
