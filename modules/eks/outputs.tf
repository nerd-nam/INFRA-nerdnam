output "cluster_name" { value = aws_eks_cluster.this.name }
output "cluster_arn" { value = aws_eks_cluster.this.arn }
output "cluster_certificate_authority_data" { value = aws_eks_cluster.this.certificate_authority[0].data }
output "cluster_endpoint" { value = aws_eks_cluster.this.endpoint }
# 관리 IP 목록. bootstrap 이 Grafana·Argo CD 공개 주소의 IP 허용 목록으로도 넘긴다.
output "public_access_cidrs" { value = aws_eks_cluster.this.vpc_config[0].public_access_cidrs }
output "node_group_names" { value = { for k, v in aws_eks_node_group.this : k => v.node_group_name } }
output "ecr_repository_arns" { value = { for k, v in aws_ecr_repository.apps : k => v.arn } }
output "ecr_repository_urls" { value = { for k, v in aws_ecr_repository.apps : k => v.repository_url } }
output "addon_versions" {
  value = merge({ for k, v in aws_eks_addon.bootstrap : k => v.addon_version }, {
    eks-pod-identity-agent = aws_eks_addon.pod_identity.addon_version
    coredns                = aws_eks_addon.coredns.addon_version
    aws-ebs-csi-driver     = aws_eks_addon.ebs_csi.addon_version
    metrics-server         = aws_eks_addon.metrics_server.addon_version
  })
}
