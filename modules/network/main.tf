locals {
  # /16의 첫 /24와 두 번째 /20을 사용해 포함 관계와 비중첩을 보장한다.
  public_cidr  = cidrsubnet(var.vpc_cidr, 8, 0)
  private_cidr = cidrsubnet(var.vpc_cidr, 4, 1)
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  # 기본 SG의 전체 egress/자기 참조 ingress를 제거한다.
  # EKS/NLB용 SG는 해당 리소스를 만드는 단계에서 별도로 정의한다.
  ingress = []
  egress  = []

  tags = { Name = "${var.name_prefix}-default-unused" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_cidr
  availability_zone       = var.availability_zones.public
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.name_prefix}-public"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.private_cidr
  availability_zone       = var.availability_zones.private
  map_public_ip_on_launch = false

  tags = {
    Name                              = "${var.name_prefix}-private"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-nat" }
}

resource "aws_nat_gateway" "this" {
  allocation_id     = aws_eip.nat.id
  subnet_id         = aws_subnet.public.id
  connectivity_type = "public"
  tags              = { Name = "${var.name_prefix}-nat" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-public" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-private" }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  vpc_endpoint_type = "Gateway"
  service_name      = "com.amazonaws.ap-northeast-2.s3"
  route_table_ids   = [aws_route_table.public.id, aws_route_table.private.id]

  # endpoint는 네트워크 경로만 제공한다. S3 접근 권한은 workload IAM/bucket policy로 제한한다.
  tags = { Name = "${var.name_prefix}-s3" }
}
