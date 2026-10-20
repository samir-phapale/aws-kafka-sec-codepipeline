variable "project_name" {
  description = "Name of the project, used for resource naming and tags"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)"
  type        = string
}

variable "conformance_pack_name" {
  description = "Name of the Phase 3 conformance pack. If null, defaults to <project>-<environment>-s3-security."
  type        = string
  default     = null
}

variable "config_snapshot_frequency_hours" {
  description = "Periodic frequency for the detective custom Config rule."
  type        = number
  default     = 24
}

variable "scope_tag_key" {
  description = "Tag key a bucket must carry to be evaluated (and remediated) by the Phase 3 rules."
  type        = string
}

variable "scope_tag_value" {
  description = "Tag value a bucket must carry to be evaluated (and remediated) by the Phase 3 rules."
  type        = string
}

variable "lambda_log_retention_days" {
  description = "CloudWatch Logs retention for the custom rule Lambdas."
  type        = number
  default     = 14
}
