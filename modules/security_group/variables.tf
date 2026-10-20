variable "project_name" {
  description = "Name of the project, used for resource naming and tags"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID the security group belongs to"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC, used to optionally allow internal Kafka access"
  type        = string
}

variable "kafka_port" {
  description = "Kafka broker (PLAINTEXT listener) port"
  type        = number
  default     = 9092
}

variable "kafka_controller_port" {
  description = "Kafka KRaft controller port"
  type        = number
  default     = 9093
}

variable "allow_internal_kafka_access" {
  description = "If true, allow Kafka client port access from anywhere inside the VPC CIDR. Defaults to false: the producer/consumer run locally on the broker, and management is done over SSM, so no inbound Kafka access is required."
  type        = bool
  default     = false
}
