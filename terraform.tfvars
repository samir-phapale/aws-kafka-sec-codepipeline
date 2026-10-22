aws_region   = "us-east-1"
project_name = "kafka-on-ec2-cp"
environment  = "dev"

vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.101.0/24", "10.0.102.0/24"]
azs                  = ["us-east-1a", "us-east-1b"]

kafka_port                  = 9092
allow_internal_kafka_access = false

instance_type    = "t3.medium"
root_volume_size = 30

kafka_version = "4.1.2"
scala_version = "2.13"

kafka_topic_name               = "demo-topic"
kafka_topic_partitions         = 3
kafka_topic_replication_factor = 1

permissions_boundary_name = "kafka-on-ec2-cp-cicd-dev-stack-boundary"
