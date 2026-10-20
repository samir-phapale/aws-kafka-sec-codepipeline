terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
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
    }
  }

  # Tags owned by the account's governance tooling, not by this configuration,
  # so Terraform neither removes nor reports them as drift:
  # - CreatedBy / CreatedDate / PrincipalId: ownership tags stamped on creation
  # - custodian_stopped: Cloud Custodian's marker on instances it stopped overnight
  ignore_tags {
    keys = ["CreatedBy", "CreatedDate", "PrincipalId", "custodian_stopped"]
  }
}
