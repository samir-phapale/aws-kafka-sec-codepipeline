variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  description = "Must match the Kafka stack's project_name"
  type        = string
  default     = "kafka-on-ec2-cp"
}

variable "environment" {
  description = "Must match the Kafka stack's environment"
  type        = string
  default     = "dev"
}

variable "github_repository" {
  description = "GitHub repository as owner/name"
  type        = string
}

variable "branch" {
  type    = string
  default = "main"
}

variable "tf_state_bucket" {
  description = "S3 bucket holding the Kafka stack's state"
  type        = string
}

variable "tf_state_key" {
  description = "State key of the Kafka stack"
  type        = string
  default     = "aws-kafka-sec-codepipeline/dev/terraform.tfstate"
}

variable "notification_email" {
  description = "Email that receives approval requests (null to skip)"
  type        = string
  default     = null
}

variable "pr_allowed_github_user_ids" {
  description = "Numeric GitHub user IDs whose pull requests are checked; empty disables the PR check"
  type        = list(string)
  default     = []
}

variable "terraform_version" {
  type    = string
  default = "1.15.4"
}

variable "conftest_version" {
  type    = string
  default = "0.71.1"
}
