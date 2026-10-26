data "aws_caller_identity" "current" {}

resource "terraform_data" "bootstrap_test" {
  input = "Terraform remote state initialized"
}