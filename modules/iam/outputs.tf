output "instance_profile_name" {
  description = "Name of the IAM instance profile to attach to the Kafka EC2 instance"
  value       = aws_iam_instance_profile.kafka_instance.name

  # The broker reads its credential at first boot; make sure the role can do
  # that (and register with SSM) before an instance is launched with it.
  depends_on = [
    aws_iam_role_policy.kafka_secrets_access,
    aws_iam_role_policy_attachment.ssm_managed_instance_core,
  ]
}

output "role_arn" {
  description = "ARN of the Kafka EC2 instance IAM role"
  value       = aws_iam_role.kafka_instance.arn
}
