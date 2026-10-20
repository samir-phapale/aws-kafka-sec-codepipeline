output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = module.vpc.private_subnet_ids
}

output "security_group_id" {
  description = "ID of the Kafka broker security group"
  value       = module.security_group.security_group_id
}

output "iam_instance_profile_name" {
  description = "Name of the IAM instance profile that will be attached to the Kafka EC2 instance"
  value       = module.iam.instance_profile_name
}

output "instance_id" {
  description = "ID of the Kafka EC2 instance (used by tests/CI via SSM)"
  value       = module.ec2_kafka.instance_id
}

output "instance_private_ip" {
  description = "Private IP of the Kafka broker"
  value       = module.ec2_kafka.private_ip
}

output "instance_public_ip" {
  description = "Public IP of the Kafka broker instance (for reference only - Kafka is not exposed on it)"
  value       = module.ec2_kafka.public_ip
}

output "kafka_topic_name" {
  description = "Name of the Kafka topic created at provisioning time"
  value       = module.ec2_kafka.topic_name
}

output "kafka_bootstrap_server" {
  description = "Kafka bootstrap server (SASL_PLAINTEXT, SCRAM-SHA-512), reachable only from inside the instance itself. On the broker, run kafka-client-config to get a client config with the credential from Secrets Manager."
  value       = "localhost:9092"
}

output "ssm_connect_command" {
  description = "AWS CLI command to open a shell on the Kafka broker via SSM Session Manager"
  value       = "aws ssm start-session --target ${module.ec2_kafka.instance_id} --region ${var.aws_region}"
}


output "phase3_secret_arn" {
  description = "ARN of the Phase 3 Secrets Manager secret."
  value       = module.secrets_manager.secret_arn
}

output "phase3_conformance_pack_name" {
  description = "Phase 3 conformance pack name (contains the detective and reactive rules and the remediation)."
  value       = module.config_controls.conformance_pack_name
}

output "compliance_scope_tag_key" {
  description = "Tag key that opts an S3 bucket into the Phase 3 Config rules."
  value       = var.compliance_scope_tag_key
}

output "compliance_scope_tag_value" {
  description = "Tag value that opts an S3 bucket into the Phase 3 Config rules."
  value       = local.compliance_scope_tag_value
}

output "phase3_remediation_document_name" {
  description = "Custom SSM Automation document run by AWS Config to remediate the reactive rule."
  value       = module.config_controls.remediation_document_name
}
