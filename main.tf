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

module "eks" {
  count  = var.enable_eks ? 1 : 0
  source = "./modules/eks"

  name                = "nerdnam-dev"
  kubernetes_version  = var.eks_kubernetes_version
  cluster_subnet_ids  = concat(module.network.public_subnet_ids, module.network.private_subnet_ids)
  public_subnet_ids   = module.network.public_subnet_ids
  private_subnet_ids  = module.network.private_subnet_ids
  admin_principal_arn = var.eks_admin_principal_arn
  public_access_cidrs = var.eks_public_access_cidrs
  instance_types      = var.eks_instance_types
  addon_versions      = var.eks_addon_versions

  depends_on = [module.network]
}
