output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = [aws_subnet.public.id]
}

output "private_subnet_ids" {
  value = [aws_subnet.private.id]
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
