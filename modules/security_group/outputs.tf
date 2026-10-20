output "security_group_id" {
  description = "ID of the Kafka broker security group"
  value       = aws_security_group.kafka.id
}
