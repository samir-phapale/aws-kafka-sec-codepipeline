output "instance_id" {
  description = "ID of the Kafka EC2 instance"
  value       = aws_instance.kafka.id
}

output "private_ip" {
  description = "Private IP address of the Kafka broker (advertised.listeners target)"
  value       = aws_instance.kafka.private_ip
}

output "public_ip" {
  description = "Public IP address of the Kafka broker instance (SSM/troubleshooting use only; Kafka itself is not exposed publicly)"
  value       = aws_instance.kafka.public_ip
}

output "topic_name" {
  description = "Name of the Kafka topic created at provisioning time"
  value       = var.topic_name
}
