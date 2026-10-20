locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

data "aws_ami" "amazon_linux_2023" {
  count       = var.ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami_id = var.ami_id != null ? var.ami_id : data.aws_ami.amazon_linux_2023[0].id
}

resource "aws_instance" "kafka" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = var.iam_instance_profile

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tpl", {
    kafka_version            = var.kafka_version
    scala_version            = var.scala_version
    topic_name               = var.topic_name
    topic_partitions         = var.topic_partitions
    topic_replication_factor = var.topic_replication_factor
    kafka_secret_arn         = var.kafka_secret_arn
    secret_region            = element(split(":", var.kafka_secret_arn), 3)
    secret_version_id        = var.kafka_secret_version_id
  })

  user_data_replace_on_change = true

  tags = {
    Name = "${local.name_prefix}-kafka-broker"
  }
}
