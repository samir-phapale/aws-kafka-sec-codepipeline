# Permissions boundary every IAM role of the Kafka stack must carry. The deploy
# role cannot create or change a stack role without it, so no commit can give
# a stack role more than this.

data "aws_iam_policy_document" "stack_boundary" {
  # Same actions as AmazonSSMManagedInstanceCore (broker).
  statement {
    sid    = "SessionManager"
    effect = "Allow"
    actions = [
      "ssm:DescribeAssociation",
      "ssm:GetDeployablePatchSnapshotForInstance",
      "ssm:GetDocument",
      "ssm:DescribeDocument",
      "ssm:GetManifest",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:ListAssociations",
      "ssm:ListInstanceAssociations",
      "ssm:PutInventory",
      "ssm:PutComplianceItems",
      "ssm:PutConfigurePackageResult",
      "ssm:UpdateAssociationStatus",
      "ssm:UpdateInstanceAssociationStatus",
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "StackSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [local.stack_secret_arn]
  }

  statement {
    sid     = "LambdaLogs"
    effect  = "Allow"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.stack_prefix}-*",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.stack_prefix}-*:*",
    ]
  }

  statement {
    sid       = "ConfigRules"
    effect    = "Allow"
    actions   = ["config:PutEvaluations", "tag:GetResources"]
    resources = ["*"]
  }

  statement {
    sid    = "BucketSecuritySettings"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:GetBucketVersioning",
      "s3:GetBucketTagging",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock",
    ]
    resources = ["arn:${local.partition}:s3:::*"]
  }
}

resource "aws_iam_policy" "stack_boundary" {
  name   = "${local.cicd_prefix}-stack-boundary"
  policy = data.aws_iam_policy_document.stack_boundary.json
}
