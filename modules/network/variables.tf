variable "name_prefix" {
  description = "리소스 이름 접두어."
  type        = string
}

variable "vpc_cidr" {
  description = "서브넷을 겹치지 않게 나누기 위한 정규화된 IPv4 /16 CIDR."
  type        = string

  validation {
    condition = try(
      cidrnetmask(var.vpc_cidr) == "255.255.0.0" &&
      cidrsubnet(var.vpc_cidr, 0, 0) == var.vpc_cidr,
      false
    )
    error_message = "vpc_cidr는 10.20.0.0/16처럼 네트워크 주소로 시작하는 IPv4 /16이어야 합니다."
  }
}

variable "availability_zones" {
  description = "EKS가 사용할 서로 다른 서울 AZ 두 개."
  type = object({
    public  = string
    private = string
  })

  validation {
    condition = (
      var.availability_zones.public != var.availability_zones.private &&
      alltrue([for az in values(var.availability_zones) : can(regex("^ap-northeast-2[a-d]$", az))])
    )
    error_message = "public/private에는 서로 다른 서울 AZ(ap-northeast-2a~d)를 지정해야 합니다."
  }
}
