# ---------------------------------------------------------------------------
# One role per job, so each stage holds only the access it needs:
#
#   validate     static checks             no AWS access beyond logs/artifacts
#   plan         plan on main / destroy    read-only + state lock
#   pr           plan on pull requests     read-only, no state lock
#   deploy       apply / destroy           PowerUser + IAM limited to the stack
#   integration  e2e tests over SSM        the broker instance and its secret
#   pipeline     CodePipeline itself       start builds, artifacts, approvals
# ---------------------------------------------------------------------------

locals {
  connection_arns = distinct([
    aws_codestarconnections_connection.github.arn,
    replace(aws_codestarconnections_connection.github.arn, ":codestar-connections:", ":codeconnections:"),
  ])

  codebuild_roles = {
    validate = {
      managed_policies = []
      policies         = [data.aws_iam_policy_document.codebuild_base.json]
    }
    plan = {
      managed_policies = ["arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"]
      policies = [
        data.aws_iam_policy_document.codebuild_base.json,
        data.aws_iam_policy_document.state_read.json,
        data.aws_iam_policy_document.state_lock.json,
        data.aws_iam_policy_document.read_only_guardrails.json,
      ]
    }
    pr = {
      managed_policies = ["arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"]
      policies = [
        data.aws_iam_policy_document.codebuild_base.json,
        data.aws_iam_policy_document.state_read.json,
        data.aws_iam_policy_document.read_only_guardrails.json,
        data.aws_iam_policy_document.github_connection.json,
      ]
    }
    deploy = {
      managed_policies = ["arn:${local.partition}:iam::aws:policy/PowerUserAccess"]
      policies = [
        data.aws_iam_policy_document.codebuild_base.json,
        data.aws_iam_policy_document.deploy_iam.json,
        data.aws_iam_policy_document.deploy_guardrails.json,
      ]
    }
    integration = {
      managed_policies = []
      policies = [
        data.aws_iam_policy_document.codebuild_base.json,
        data.aws_iam_policy_document.integration.json,
      ]
    }
  }

  codebuild_managed_attachments = merge([
    for role, cfg in local.codebuild_roles : {
      for arn in cfg.managed_policies : "${role}:${basename(arn)}" => { role = role, policy_arn = arn }
    }
  ]...)
}

data "aws_iam_policy_document" "codebuild_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  for_each = local.codebuild_roles

  name               = "${local.cicd_prefix}-codebuild-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume_role.json
}

data "aws_iam_policy_document" "codebuild_combined" {
  for_each = local.codebuild_roles

  source_policy_documents = each.value.policies
}

resource "aws_iam_role_policy" "codebuild" {
  for_each = local.codebuild_roles

  name   = "${local.cicd_prefix}-codebuild-${each.key}"
  role   = aws_iam_role.codebuild[each.key].id
  policy = data.aws_iam_policy_document.codebuild_combined[each.key].json
}

resource "aws_iam_role_policy_attachment" "codebuild" {
  for_each = local.codebuild_managed_attachments

  role       = aws_iam_role.codebuild[each.value.role].name
  policy_arn = each.value.policy_arn
}

# --- Shared by every build: logs, pipeline artifacts, the pipeline key -----

data "aws_iam_policy_document" "codebuild_base" {
  statement {
    sid       = "BuildLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${local.codebuild_logs_arn}:*"]
  }

  statement {
    sid    = "PipelineArtifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:GetBucketAcl",
      "s3:GetBucketLocation",
    ]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid       = "PipelineKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = [aws_kms_key.cicd.arn]
  }
}

# --- Terraform state ---------------------------------------------------------

data "aws_iam_policy_document" "state_read" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
  }

  statement {
    sid       = "ReadState"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [local.state_object_arn, local.state_lock_arn]
  }

  # Refreshing aws_secretsmanager_secret_version reads the value.
  statement {
    sid       = "RefreshStackSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.stack_secret_arn]
  }

  dynamic "statement" {
    for_each = var.tf_state_kms_key_arn == null ? [] : [var.tf_state_kms_key_arn]
    content {
      sid       = "StateKey"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
      resources = [statement.value]
    }
  }
}

data "aws_iam_policy_document" "state_lock" {
  statement {
    sid       = "StateLockFile"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = [local.state_lock_arn]
  }
}

# ReadOnlyAccess can read every S3 object and SSM parameter in the account.
# Plans only need the state and the pipeline artifacts.
data "aws_iam_policy_document" "read_only_guardrails" {
  statement {
    sid     = "DenyObjectReadsOutsideStateAndArtifacts"
    effect  = "Deny"
    actions = ["s3:GetObject*"]
    not_resources = [
      "${local.state_bucket_arn}/*",
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }

  statement {
    sid    = "DenyParameterValues"
    effect = "Deny"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:GetParameterHistory",
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "github_connection" {
  statement {
    sid    = "UseGitHubConnection"
    effect = "Allow"
    # CodeBuild checks GetConnection when a project with a CodeConnections
    # source is created or updated.
    actions = [
      "codeconnections:UseConnection",
      "codeconnections:GetConnection",
      "codeconnections:GetConnectionToken",
      "codestar-connections:UseConnection",
      "codestar-connections:GetConnection",
      "codestar-connections:GetConnectionToken",
    ]
    resources = local.connection_arns
  }
}

# --- Deploy: IAM limited to the Kafka stack's own roles ---------------------

data "aws_iam_policy_document" "deploy_iam" {
  statement {
    sid    = "ManageStackRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${local.stack_prefix}-*"]
  }

  # Only the AWS managed policies the stack actually attaches, so the role
  # cannot hand AdministratorAccess to a role it creates.
  statement {
    sid       = "AttachApprovedManagedPolicies"
    effect    = "Allow"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${local.stack_prefix}-*"]

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values = [
        "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
        "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
      ]
    }
  }

  statement {
    sid    = "ManageStackInstanceProfiles"
    effect = "Allow"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/${local.stack_prefix}-*"]
  }

  statement {
    sid       = "PassStackRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${local.stack_prefix}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "ec2.amazonaws.com",
        "lambda.amazonaws.com",
        "ssm.amazonaws.com",
        "config.amazonaws.com",
      ]
    }
  }

  statement {
    sid       = "ReadIamForRefresh"
    effect    = "Allow"
    actions   = ["iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions"]
    resources = ["*"]
  }
}

# PowerUserAccess covers CodeBuild, CodePipeline, KMS, S3 and SNS, so it
# would let the deploy role rewrite the pipeline that runs it. Deny that.
data "aws_iam_policy_document" "deploy_guardrails" {
  statement {
    sid       = "DenyPipelineRoles"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${local.cicd_prefix}-*"]
  }

  statement {
    sid       = "DenyPipelineBuildProjects"
    effect    = "Deny"
    actions   = ["codebuild:*"]
    resources = [local.codebuild_proj_arn]
  }

  statement {
    sid       = "DenyPipelines"
    effect    = "Deny"
    actions   = ["codepipeline:*"]
    resources = [local.codepipeline_arn, "${local.codepipeline_arn}/*"]
  }

  statement {
    sid    = "DenyPipelineKeyAdministration"
    effect = "Deny"
    actions = [
      "kms:PutKeyPolicy",
      "kms:ScheduleKeyDeletion",
      "kms:DisableKey",
      "kms:DisableKeyRotation",
      "kms:CreateGrant",
      "kms:DeleteAlias",
      "kms:UpdateAlias",
    ]
    resources = [aws_kms_key.cicd.arn]
  }

  statement {
    sid    = "DenyArtifactBucketConfiguration"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:PutBucketVersioning",
      "s3:PutBucketAcl",
      "s3:PutBucketOwnershipControls",
    ]
    resources = [aws_s3_bucket.artifacts.arn]
  }

  statement {
    sid       = "DenyNotificationTopic"
    effect    = "Deny"
    actions   = ["sns:DeleteTopic", "sns:SetTopicAttributes", "sns:Subscribe", "sns:AddPermission", "sns:RemovePermission"]
    resources = [aws_sns_topic.cicd.arn]
  }

  statement {
    sid       = "DenyGitHubConnection"
    effect    = "Deny"
    actions   = ["codeconnections:*", "codestar-connections:*"]
    resources = local.connection_arns
  }

  statement {
    sid       = "DenyPipelineLogDeletion"
    effect    = "Deny"
    actions   = ["logs:DeleteLogGroup", "logs:DeleteLogStream", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy"]
    resources = [local.codebuild_logs_arn, "${local.codebuild_logs_arn}:*"]
  }
}

# --- Integration tests: the broker and its secret, nothing else -------------

data "aws_iam_policy_document" "integration" {
  statement {
    sid    = "DescribeInstances"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeInstanceAttribute",
      "ssm:DescribeInstanceInformation",
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
    ]
    resources = ["*"]
  }

  # Cloud Custodian stops the broker nightly.
  statement {
    sid       = "StartStackInstances"
    effect    = "Allow"
    actions   = ["ec2:StartInstances"]
    resources = ["arn:${local.partition}:ec2:${local.region}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project_name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [var.environment]
    }
  }

  statement {
    sid       = "RunCommandsOnStackInstances"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:${local.partition}:ec2:${local.region}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = [var.project_name]
    }

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Environment"
      values   = [var.environment]
    }
  }

  statement {
    sid       = "RunShellScriptDocument"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:${local.partition}:ssm:${local.region}::document/AWS-RunShellScript"]
  }

  # test_secret_not_in_user_data compares the user data with the real value.
  statement {
    sid       = "ReadStackSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.stack_secret_arn]
  }
}

# ---------------------------------------------------------------------------
# CodePipeline service role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "codepipeline_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "codepipeline" {
  name               = "${local.cicd_prefix}-codepipeline"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume_role.json
}

data "aws_iam_policy_document" "codepipeline" {
  source_policy_documents = [data.aws_iam_policy_document.github_connection.json]

  statement {
    sid    = "Artifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:GetBucketVersioning",
      "s3:GetBucketLocation",
    ]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid       = "PipelineKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = [aws_kms_key.cicd.arn]
  }

  statement {
    sid       = "RunBuilds"
    effect    = "Allow"
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds", "codebuild:StopBuild"]
    resources = [local.codebuild_proj_arn]
  }

  statement {
    sid       = "ApprovalNotifications"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.cicd.arn]
  }
}

resource "aws_iam_role_policy" "codepipeline" {
  name   = "${local.cicd_prefix}-codepipeline"
  role   = aws_iam_role.codepipeline.id
  policy = data.aws_iam_policy_document.codepipeline.json
}
