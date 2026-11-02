provider "aws" {
  region              = "ap-northeast-2"
  allowed_account_ids = ["082139775699"]

  default_tags {
    tags = {
      Project     = "nerdnam"
      Environment = "dev"
      ManagedBy   = "Terraform"
    }
  }
}
