terraform {
  required_version = ">= 1.15.0, < 2.0.0"
  required_providers {
    helm = { source = "hashicorp/helm", version = ">= 3.0.0, < 4.0.0" }
  }
  backend "s3" {
    bucket       = "nerdnam-terraform-082139775699-ap-northeast-2-an"
    key          = "dev/bootstrap.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
