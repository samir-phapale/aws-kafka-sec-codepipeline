variable "aws_region" {
  description = "AWS region for the pipeline (same region as the Kafka stack)"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name of the Kafka stack. Must match the stack's project_name: deploy permissions are scoped to <project>-<environment>-* resources."
  type        = string
  default     = "kafka-on-ec2-cp"
}

variable "environment" {
  description = "Environment of the Kafka stack this pipeline deploys. Must match the stack's environment."
  type        = string
  default     = "dev"
}

variable "github_repository" {
  description = "GitHub repository the pipeline builds, as owner/name"
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Use the owner/name form, e.g. my-org/aws-kafka-sec-codepipeline."
  }
}

variable "branch" {
  description = "Branch that is deployed; pull requests targeting it are checked"
  type        = string
  default     = "main"
}

variable "tf_state_bucket" {
  description = "S3 bucket holding the Kafka stack's Terraform state"
  type        = string
}

variable "tf_state_key" {
  description = "State object key of the Kafka stack"
  type        = string
  default     = "aws-kafka-sec-codepipeline/dev/terraform.tfstate"
}

variable "tf_state_kms_key_arn" {
  description = "KMS key ARN, if the state bucket is encrypted with a customer managed key (null for SSE-S3)"
  type        = string
  default     = null
}

variable "notification_email" {
  description = "Email subscribed to approval requests and pipeline results (null to skip; confirm the subscription email AWS sends)"
  type        = string
  default     = null
}

variable "pr_allowed_github_user_ids" {
  description = "Numeric GitHub user IDs whose pull requests get a CodeBuild check. Empty disables the PR check. Fork PRs from anyone else never run."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.pr_allowed_github_user_ids : can(regex("^[0-9]+$", id))])
    error_message = "Use numeric GitHub user IDs (https://api.github.com/users/<login> -> id), not logins."
  }
}

variable "terraform_version" {
  description = "Terraform CLI version installed in CodeBuild (checksum-verified)"
  type        = string
  default     = "1.15.4"
}

variable "conftest_version" {
  description = "conftest version installed in CodeBuild (checksum-verified)"
  type        = string
  default     = "0.71.1"
}

variable "codebuild_image" {
  description = "CodeBuild managed image"
  type        = string
  default     = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for CodeBuild logs"
  type        = number
  default     = 30
}

variable "artifact_retention_days" {
  description = "Days pipeline artifacts (source zips, tfplan files) are kept"
  type        = number
  default     = 30
}
