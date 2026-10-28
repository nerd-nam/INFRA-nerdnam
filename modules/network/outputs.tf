output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = [aws_subnet.public.id]
  # 서브넷을 쓰는 노드는 인터넷 및 S3 경로까지 준비된 후 생성한다.
  depends_on = [aws_route.public_default, aws_route_table_association.public, aws_vpc_endpoint.s3]
}

output "private_subnet_ids" {
  value      = [aws_subnet.private.id]
  depends_on = [aws_route.private_default, aws_route_table_association.private, aws_vpc_endpoint.s3]
}

output "subnet_cidrs" {
  value = { public = local.public_cidr, private = local.private_cidr }
}

output "route_table_ids" {
  value = { public = aws_route_table.public.id, private = aws_route_table.private.id }
}

output "nat_gateway_id" {
  value = aws_nat_gateway.this.id
}

output "nat_public_ip" {
  value = aws_eip.nat.public_ip
}

output "s3_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}
