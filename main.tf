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
  source = "./modules/eks"

  name                = "nerdnam-dev"
  kubernetes_version  = var.eks_kubernetes_version
  cluster_subnet_ids  = concat(module.network.public_subnet_ids, module.network.private_subnet_ids)
  app_subnet_ids      = module.network.app_subnet_ids
  private_subnet_ids  = module.network.private_subnet_ids
  admin_principal_arn = var.eks_admin_principal_arn
  public_access_cidrs = var.eks_public_access_cidrs
  instance_types      = var.eks_instance_types
  addon_versions      = var.eks_addon_versions
  node_count          = var.eks_node_count
}

module "platform" {
  source          = "./modules/platform"
  cluster_name    = module.eks.cluster_name
  cluster_arn     = module.eks.cluster_arn
  route53_zone_id = var.route53_zone_id
}

module "observability" {
  source       = "./modules/observability"
  name         = "nerdnam-dev"
  region       = "ap-northeast-2"
  account_id   = data.aws_caller_identity.current.account_id
  cluster_name = module.eks.cluster_name
  cluster_arn  = module.eks.cluster_arn
}

module "workload" {
  source              = "./modules/workload"
  name                = "nerdnam-dev"
  region              = "ap-northeast-2"
  account_id          = data.aws_caller_identity.current.account_id
  cluster_name        = module.eks.cluster_name
  cluster_arn         = module.eks.cluster_arn
  ecr_repository_arns = module.eks.ecr_repository_arns
}

# GitHub Actions 의 Terraform plan(읽기 전용)·apply(사람 승인 Environment 전용) 역할 (docs/Terraform-CI.md)
module "terraform_ci" {
  source            = "./modules/terraform_ci"
  name              = "nerdnam-dev"
  account_id        = data.aws_caller_identity.current.account_id
  oidc_provider_arn = module.workload.github_oidc_provider_arn
  state_bucket      = "nerdnam-terraform-082139775699-ap-northeast-2-an"
  state_key         = "dev/terraform.tfstate"
}
