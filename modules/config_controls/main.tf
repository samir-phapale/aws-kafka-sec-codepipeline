locals {
  name_prefix = "${var.project_name}-${var.environment}"

  config_frequency = {
    1  = "One_Hour"
    3  = "Three_Hours"
    6  = "Six_Hours"
    12 = "Twelve_Hours"
    24 = "TwentyFour_Hours"
  }[var.config_snapshot_frequency_hours]

  conformance_pack_name = coalesce(var.conformance_pack_name, "${local.name_prefix}-s3-security")
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# ---------------------------------------------------------------------------
# AWS Config recorder
#
# This module deliberately does NOT create a configuration recorder or
# delivery channel. AWS allows one recorder per account/region, and in a
# Control Tower account it is owned by Control Tower
# (aws-controltower-BaselineConfigRecorder, recording all resource types).
# The rules below rely on that existing recorder.
#
# Every rule is scoped to buckets carrying var.scope_tag_key =
# var.scope_tag_value, so the automatic remediation can never touch buckets
# owned by other teams in the shared account.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Custom rule Lambdas (one least-privilege role each)
# ---------------------------------------------------------------------------

data "archive_file" "detective" {
  type        = "zip"
  source_file = "${path.module}/lambda/detective/handler.py"
  output_path = "${path.module}/lambda/detective/detective.zip"
}

data "archive_file" "reactive" {
  type        = "zip"
  source_file = "${path.module}/lambda/reactive/handler.py"
  output_path = "${path.module}/lambda/reactive/reactive.zip"
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "detective_lambda" {
  statement {
    sid       = "FindScopedBuckets"
    effect    = "Allow"
    actions   = ["tag:GetResources"]
    resources = ["*"]
  }

  statement {
    sid    = "ReadBucketVersioning"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:GetBucketVersioning"
    ]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::*"]
  }

  statement {
    sid       = "PublishConfigEvaluations"
    effect    = "Allow"
    actions   = ["config:PutEvaluations"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "reactive_lambda" {
  statement {
    sid    = "ReadBucketPublicAccessBlock"
    effect = "Allow"
    actions = [
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketTagging"
    ]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::*"]
  }

  statement {
    sid       = "PublishConfigEvaluations"
    effect    = "Allow"
    actions   = ["config:PutEvaluations"]
    resources = ["*"]
  }
}

locals {
  lambdas = {
    detective = {
      description = "Phase 3 detective Config rule: S3 bucket versioning must be enabled"
      archive     = data.archive_file.detective
      policy      = data.aws_iam_policy_document.detective_lambda.json
      timeout     = 120
    }
    reactive = {
      description = "Phase 3 reactive Config rule: all four S3 Public Access Block settings must be enabled"
      archive     = data.archive_file.reactive
      policy      = data.aws_iam_policy_document.reactive_lambda.json
      timeout     = 30
    }
  }
}

resource "aws_iam_role" "lambda" {
  for_each = local.lambdas

  name               = "${local.name_prefix}-config-${each.key}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  for_each = local.lambdas

  role       = aws_iam_role.lambda[each.key].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda" {
  for_each = local.lambdas

  name   = "${local.name_prefix}-config-${each.key}"
  role   = aws_iam_role.lambda[each.key].id
  policy = each.value.policy
}

resource "aws_cloudwatch_log_group" "lambda" {
  for_each = local.lambdas

  name              = "/aws/lambda/${local.name_prefix}-config-${each.key}"
  retention_in_days = var.lambda_log_retention_days
}

resource "aws_lambda_function" "rule" {
  for_each = local.lambdas

  function_name    = "${local.name_prefix}-config-${each.key}"
  description      = each.value.description
  role             = aws_iam_role.lambda[each.key].arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = each.value.archive.output_path
  source_code_hash = each.value.archive.output_base64sha256
  timeout          = each.value.timeout

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda,
    aws_iam_role_policy_attachment.lambda_logs
  ]
}

resource "aws_lambda_permission" "config" {
  for_each = local.lambdas

  statement_id   = "AllowConfigInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.rule[each.key].function_name
  principal      = "config.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
}

# ---------------------------------------------------------------------------
# Reactive remediation: our own SSM Automation document, run by AWS Config
# against a NON_COMPLIANT bucket under a dedicated role.
# ---------------------------------------------------------------------------

resource "aws_ssm_document" "s3_public_access_remediation" {
  name            = "${local.name_prefix}-s3-public-access-remediation"
  document_type   = "Automation"
  document_format = "YAML"

  content = templatefile("${path.module}/templates/remediation_document.yaml", {
    script = file("${path.module}/remediation/s3_public_access_block.py")
  })
}

data "aws_iam_policy_document" "automation_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "automation" {
  name               = "${local.name_prefix}-config-remediation-role"
  assume_role_policy = data.aws_iam_policy_document.automation_assume_role.json
}

data "aws_iam_policy_document" "automation_s3" {
  statement {
    sid    = "RemediateBucketPublicAccessBlock"
    effect = "Allow"
    actions = [
      "s3:GetBucketTagging",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock"
    ]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::*"]
  }
}

resource "aws_iam_role_policy" "automation_s3" {
  name   = "${local.name_prefix}-remediation-s3"
  role   = aws_iam_role.automation.id
  policy = data.aws_iam_policy_document.automation_s3.json
}

# ---------------------------------------------------------------------------
# Conformance pack: the single deployment unit for both rules and the
# reactive remediation.
# ---------------------------------------------------------------------------

resource "aws_config_conformance_pack" "s3_security" {
  name = local.conformance_pack_name

  template_body = templatefile("${path.module}/templates/conformance_pack.yaml", {
    name_prefix          = local.name_prefix
    detective_lambda_arn = aws_lambda_function.rule["detective"].arn
    reactive_lambda_arn  = aws_lambda_function.rule["reactive"].arn
    remediation_role_arn = aws_iam_role.automation.arn
    remediation_document = aws_ssm_document.s3_public_access_remediation.name
    detective_frequency  = local.config_frequency
    scope_tag_key        = var.scope_tag_key
    scope_tag_value      = var.scope_tag_value
  })

  depends_on = [
    aws_lambda_permission.config,
    aws_iam_role_policy.automation_s3,
    aws_ssm_document.s3_public_access_remediation
  ]
}
