variable "project_name" {
  description = "Name of the project, used for resource naming and tags"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)"
  type        = string
}


variable "phase3_secret_arn" {
  description = "ARN of the Phase 3 Secrets Manager secret the Kafka instance may read."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for the IAM roles in this module (null for none)"
  type        = string
  default     = null
}
