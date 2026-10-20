terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }

  # Separate state from the Kafka stack: pass a different key, e.g.
  # aws-kafka-sec-codepipeline/cicd/terraform.tfstate (see backend.hcl.example).
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

  # Same account governance tags the Kafka stack ignores.
  ignore_tags {
    keys = ["CreatedBy", "CreatedDate", "PrincipalId", "custodian_stopped"]
  }
}
