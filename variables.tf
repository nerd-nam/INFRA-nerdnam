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
