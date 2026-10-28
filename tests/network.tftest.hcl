# AWS를 호출하거나 실제 리소스를 생성하지 않는 네트워크 계약 검증.
mock_provider "aws" {}

run "network_isolation" {
  # mock 상태에서 ID를 생성해 리소스 간 연결까지 검증한다. 실제 AWS apply가 아니다.
  command = apply

  module {
    source = "./modules/network"
  }

  variables {
    name_prefix = "nerdnam-test"
    vpc_cidr    = "10.20.0.0/16"
    availability_zones = {
      public  = "ap-northeast-2a"
      private = "ap-northeast-2c"
    }
  }

  assert {
    condition = (
      aws_vpc.this.enable_dns_support && aws_vpc.this.enable_dns_hostnames &&
      aws_subnet.public.availability_zone != aws_subnet.private.availability_zone &&
      aws_subnet.public.cidr_block == "10.20.0.0/24" &&
      aws_subnet.private.cidr_block == "10.20.16.0/20"
    )
    error_message = "EKS DNS 및 서로 다른 AZ의 비중첩 서브넷 구성이 필요합니다."
  }

  assert {
    condition = (
      !aws_subnet.private.map_public_ip_on_launch &&
      aws_route.private_default.nat_gateway_id == aws_nat_gateway.this.id &&
      aws_route_table_association.private.route_table_id == aws_route.private_default.route_table_id &&
      aws_route_table_association.private.subnet_id == aws_subnet.private.id &&
      aws_nat_gateway.this.subnet_id == aws_subnet.public.id &&
      aws_route.public_default.gateway_id == aws_internet_gateway.this.id &&
      aws_route_table_association.public.route_table_id == aws_route.public_default.route_table_id
    )
    error_message = "private는 공인 IP 없이 NAT를 사용하고, NAT가 위치한 public은 IGW를 사용해야 합니다."
  }

  assert {
    condition = (
      length(aws_default_security_group.this.ingress) == 0 &&
      length(aws_default_security_group.this.egress) == 0 &&
      aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" &&
      toset(aws_vpc_endpoint.s3.route_table_ids) == toset([aws_route_table.public.id, aws_route_table.private.id])
    )
    error_message = "기본 SG는 비워 두고 두 서브넷의 S3 통신을 Gateway endpoint로 연결해야 합니다."
  }
}

run "reject_same_az" {
  command = plan

  module {
    source = "./modules/network"
  }

  variables {
    name_prefix = "nerdnam-test"
    vpc_cidr    = "10.20.0.0/16"
    availability_zones = {
      public  = "ap-northeast-2a"
      private = "ap-northeast-2a"
    }
  }

  expect_failures = [var.availability_zones]
}

run "reject_non_network_cidr" {
  command = plan

  module {
    source = "./modules/network"
  }

  variables {
    name_prefix = "nerdnam-test"
    vpc_cidr    = "10.20.1.0/16"
    availability_zones = {
      public  = "ap-northeast-2a"
      private = "ap-northeast-2c"
    }
  }

  expect_failures = [var.vpc_cidr]
}
