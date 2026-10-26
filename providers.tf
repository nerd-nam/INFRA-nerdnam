provider "aws" {
  region = "ap-northeast-2"

  default_tags {
    tags = {
      Project     = "nerdnam"
      Environment = "dev"
      ManagedBy   = "Terraform"
    }
  }
}