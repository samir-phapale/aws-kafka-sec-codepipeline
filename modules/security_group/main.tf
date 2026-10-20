locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

resource "aws_security_group" "kafka" {
  name        = "${local.name_prefix}-kafka-sg"
  description = "Security group for the Kafka broker EC2 instance"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${local.name_prefix}-kafka-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "all_outbound" {
  security_group_id = aws_security_group.kafka.id
  description       = "Allow all outbound traffic (required for yum/dnf, Kafka download, SSM endpoints)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "kafka_broker_self" {
  security_group_id            = aws_security_group.kafka.id
  description                  = "Kafka broker port from within this security group"
  referenced_security_group_id = aws_security_group.kafka.id
  from_port                    = var.kafka_port
  to_port                      = var.kafka_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "kafka_controller_self" {
  security_group_id            = aws_security_group.kafka.id
  description                  = "Kafka KRaft controller port from within this security group"
  referenced_security_group_id = aws_security_group.kafka.id
  from_port                    = var.kafka_controller_port
  to_port                      = var.kafka_controller_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "kafka_broker_vpc" {
  count             = var.allow_internal_kafka_access ? 1 : 0
  security_group_id = aws_security_group.kafka.id
  description       = "Kafka broker port from anywhere inside the VPC (opt-in, for local testing/other in-VPC clients)"
  cidr_ipv4         = var.vpc_cidr
  from_port         = var.kafka_port
  to_port           = var.kafka_port
  ip_protocol       = "tcp"
}
