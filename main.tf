data "aws_caller_identity" "current" {}

resource "terraform_data" "bootstrap_test" {
  input = "Terraform remote state initialized"
}

module "network" {
  source = "./modules/network"

  name_prefix        = "nerdnam-dev"
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
}
