terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Phase       = "phase-3"
      Component   = "cicd"
    }
  }

  ignore_tags {
    keys = ["CreatedBy", "CreatedDate", "PrincipalId", "custodian_stopped"]
  }
}
