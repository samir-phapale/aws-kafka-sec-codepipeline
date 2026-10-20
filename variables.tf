variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name of the project, used for resource naming and tags"
  type        = string
  default     = "kafka-on-ec2-cp"
}

variable "environment" {
  description = "Deployment environment name"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (reserved for future use)"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

variable "azs" {
  description = "Availability zones to spread subnets across"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "kafka_port" {
  description = "Kafka broker (PLAINTEXT listener) port"
  type        = number
  default     = 9092
}

variable "allow_internal_kafka_access" {
  description = "If true, allow Kafka client port access from anywhere inside the VPC CIDR (not required for the smoke tests, which run locally on the broker via SSM)"
  type        = bool
  default     = false
}

variable "instance_type" {
  description = "EC2 instance type for the Kafka broker"
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB - must be >= the root snapshot size of the AMI in use (current Amazon Linux 2023 AMIs require at least 30)"
  type        = number
  default     = 30
}

variable "kafka_version" {
  description = "Apache Kafka version to install - must be a version still hosted on Apache's fast CDN mirror (dlcdn.apache.org), not one that has fallen back to the throttled archive.apache.org"
  type        = string
  default     = "4.1.2"
}

variable "scala_version" {
  description = "Scala build version of the Kafka distribution to install"
  type        = string
  default     = "2.13"
}

variable "kafka_topic_name" {
  description = "Name of the Kafka topic to create at provisioning time"
  type        = string
  default     = "demo-topic"
}

variable "kafka_topic_partitions" {
  description = "Number of partitions for the demo topic"
  type        = number
  default     = 3
}

variable "kafka_topic_replication_factor" {
  description = "Replication factor for the demo topic (must be 1 for a single-broker cluster)"
  type        = number
  default     = 1
}


variable "conformance_pack_name" {
  description = "Name of the Phase 3 AWS Config conformance pack. If null, defaults to <project>-<environment>-s3-security."
  type        = string
  default     = null
}

variable "config_snapshot_frequency_hours" {
  description = "Periodic frequency for the detective custom Config rule."
  type        = number
  default     = 24

  validation {
    condition     = contains([1, 3, 6, 12, 24], var.config_snapshot_frequency_hours)
    error_message = "Use one of the AWS Config supported periodic frequencies: 1, 3, 6, 12, or 24 hours."
  }
}

variable "compliance_scope_tag_key" {
  description = "Tag key that opts an S3 bucket into the Phase 3 Config rules. Only tagged buckets are evaluated and auto-remediated, so other teams' buckets in the shared account are never touched."
  type        = string
  default     = "Phase3Scope"
}

variable "compliance_scope_tag_value" {
  description = "Tag value that opts an S3 bucket into the Phase 3 Config rules. If null, defaults to <project>-<environment>."
  type        = string
  default     = null
}
