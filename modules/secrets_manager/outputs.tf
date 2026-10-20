output "secret_arn" {
  description = "ARN of the Phase 3 Secrets Manager secret."
  value       = aws_secretsmanager_secret.phase3.arn
}

output "secret_name" {
  description = "Name of the Phase 3 Secrets Manager secret."
  value       = aws_secretsmanager_secret.phase3.name
}

output "secret_version_id" {
  description = "Version ID of the current secret value; changes whenever the credential changes."
  value       = aws_secretsmanager_secret_version.phase3.version_id
}
