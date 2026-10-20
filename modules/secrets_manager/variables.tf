variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "secret_username" {
  description = "Demo username stored in the Phase 3 secret."
  type        = string
  default     = "kafka-phase3"
}
