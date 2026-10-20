variable "project_name" {
  description = "Name of the project, used for resource naming and tags"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)"
  type        = string
}

variable "subnet_id" {
  description = "Subnet to launch the Kafka EC2 instance in"
  type        = string
}

variable "security_group_id" {
  description = "Security group ID to attach to the Kafka EC2 instance"
  type        = string
}

variable "iam_instance_profile" {
  description = "IAM instance profile name to attach to the Kafka EC2 instance"
  type        = string
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

variable "ami_id" {
  description = "AMI ID to use. If null, the latest Amazon Linux 2023 AMI is looked up automatically."
  type        = string
  default     = null
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

variable "topic_name" {
  description = "Name of the Kafka topic to create at provisioning time"
  type        = string
  default     = "demo-topic"
}

variable "topic_partitions" {
  description = "Number of partitions for the demo topic"
  type        = number
  default     = 3
}

variable "topic_replication_factor" {
  description = "Replication factor for the demo topic (must be 1 for a single-broker cluster)"
  type        = number
  default     = 1
}

variable "kafka_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the SASL/SCRAM credential ({username, password}). Only the ARN is placed in user data, never the value."
  type        = string
}

variable "kafka_secret_version_id" {
  description = "Version ID of the secret value. Part of user data so a new credential replaces the broker, which is then formatted with it."
  type        = string
}
