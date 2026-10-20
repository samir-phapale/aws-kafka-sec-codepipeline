locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "kafka_instance" {
  name               = "${local.name_prefix}-kafka-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "${local.name_prefix}-kafka-instance-role"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  role       = aws_iam_role.kafka_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "kafka_instance" {
  name = "${local.name_prefix}-kafka-instance-profile"
  role = aws_iam_role.kafka_instance.name
}


data "aws_iam_policy_document" "kafka_secrets_access" {
  statement {
    sid    = "ReadPhase3Secret"
    effect = "Allow"

    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue"
    ]

    resources = [var.phase3_secret_arn]
  }
}

resource "aws_iam_role_policy" "kafka_secrets_access" {
  name   = "${local.name_prefix}-phase3-secret-access"
  role   = aws_iam_role.kafka_instance.id
  policy = data.aws_iam_policy_document.kafka_secrets_access.json
}
