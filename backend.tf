terraform {
  backend "s3" {
    bucket       = "nerdnam-terraform-082139775699-ap-northeast-2-an"
    key          = "dev/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}