data "terraform_remote_state" "aws" {
  backend = "s3"
  config = {
    bucket = "nerdnam-terraform-082139775699-ap-northeast-2-an"
    key    = "dev/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
provider "helm" {
  kubernetes = {
    host                   = data.terraform_remote_state.aws.outputs.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.aws.outputs.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--region", "ap-northeast-2", "--cluster-name", data.terraform_remote_state.aws.outputs.eks.cluster_name]
    }
  }
}
locals {
  charts           = jsondecode(file("${path.module}/../gitops/charts.lock.json"))
  seed_source_hash = sha256(join("", [for name in sort(tolist(fileset("${path.module}/../gitops/seed", "**"))) : filesha256("${path.module}/../gitops/seed/${name}")]))
  environment = {
    clusterName     = data.terraform_remote_state.aws.outputs.eks.cluster_name
    region          = "ap-northeast-2"
    vpcId           = data.terraform_remote_state.aws.outputs.network.vpc_id
    publicSubnetIds = data.terraform_remote_state.aws.outputs.network.public_subnet_ids
    hostedZoneId    = data.terraform_remote_state.aws.outputs.platform.route53_zone_id
    secretArns      = data.terraform_remote_state.aws.outputs.platform.secret_arns
    hostname        = var.sample_hostname
    appHostname     = var.app_hostname
    acmeEmail       = var.acme_email
    acmeServer      = var.acme_server
  }
}
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = local.charts["argo-cd"].repo
  chart            = "argo-cd"
  version          = local.charts["argo-cd"].version
  values           = [file("${path.module}/argocd-values.yaml")]
  atomic           = true
  timeout          = 900
}
resource "helm_release" "seed" {
  name      = "nerdnam-gitops-seed"
  namespace = "argocd"
  chart     = "${path.module}/../gitops/seed"
  # 로컬 seed chart의 파일 변경도 Helm release 갱신으로 인식한다.
  values     = [yamlencode({ gitRevision = var.git_revision, environment = local.environment, seedSourceHash = local.seed_source_hash })]
  depends_on = [helm_release.argocd]
}
