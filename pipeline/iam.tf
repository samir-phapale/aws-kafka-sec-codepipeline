# One role per CodeBuild job:
#   validate     static checks          logs + pipeline artifacts
#   pr           static checks on PRs   logs only (it runs the PR author's code)
#   plan         terraform plan         ReadOnlyAccess + its own state
#   deploy       apply / destroy        PowerUserAccess + boundary-capped stack roles
#   integration  e2e tests              the broker and its secret

locals {
  connection_arns = distinct([
    aws_codestarconnections_connection.github.arn,
    replace(aws_codestarconnections_connection.github.arn, ":codestar-connections:", ":codeconnections:"),
  ])

  # The only S3 objects plan and deploy may touch.
  own_objects = [local.state_object_arn, local.state_lock_arn, "${aws_s3_bucket.artifacts.arn}/*"]

  codebuild_roles = {
    validate = {
      managed_policy = null
      policies       = [data.aws_iam_policy_document.logs.json, data.aws_iam_policy_document.artifacts.json]
    }
    pr = {
      managed_policy = null
      policies       = [data.aws_iam_policy_document.logs.json, data.aws_iam_policy_document.github_connection.json]
    }
    plan = {
      managed_policy = "ReadOnlyAccess"
      policies = [
        data.aws_iam_policy_document.logs.json,
        data.aws_iam_policy_document.artifacts.json,
        data.aws_iam_policy_document.plan.json,
      ]
    }
    deploy = {
      managed_policy = "PowerUserAccess"
      policies = [
        data.aws_iam_policy_document.logs.json,
        data.aws_iam_policy_document.artifacts.json,
        data.aws_iam_policy_document.deploy.json,
        data.aws_iam_policy_document.deploy_guardrails.json,
      ]
    }
    integration = {
      managed_policy = null
      policies = [
        data.aws_iam_policy_document.logs.json,
        data.aws_iam_policy_document.artifacts.json,
        data.aws_iam_policy_document.integration.json,
      ]
    }
  }
}

data "aws_iam_policy_document" "codebuild_assume_role" {
  statement {
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

data "aws_iam_policy_document" "codebuild" {
  for_each = local.codebuild_roles

  source_policy_documents = each.value.policies
}

resource "aws_iam_role_policy" "codebuild" {
  for_each = local.codebuild_roles

  name   = "${local.cicd_prefix}-codebuild-${each.key}"
  role   = aws_iam_role.codebuild[each.key].id
  policy = data.aws_iam_policy_document.codebuild[each.key].json
}

resource "aws_iam_role_policy_attachment" "codebuild" {
  for_each = { for k, v in local.codebuild_roles : k => v.managed_policy if v.managed_policy != null }

  role       = aws_iam_role.codebuild[each.key].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# --- Building blocks -----------------------------------------------------------

data "aws_iam_policy_document" "logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${local.codebuild_logs_arn}:*"]
  }
}

data "aws_iam_policy_document" "artifacts" {
  statement {
    sid       = "Artifacts"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketAcl", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid       = "ArtifactsKey"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = [aws_kms_key.cicd.arn]
  }
}

data "aws_iam_policy_document" "github_connection" {
  statement {
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

# --- Plan ----------------------------------------------------------------------

data "aws_iam_policy_document" "plan" {
  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
  }

  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = [local.state_object_arn, local.state_lock_arn]
  }

  statement {
    sid       = "StateLock"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = [local.state_lock_arn]
  }

  # Refreshing aws_secretsmanager_secret_version reads the value.
  statement {
    sid       = "RefreshStackSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.stack_secret_arn]
  }

  # ReadOnlyAccess can read every S3 object (other state files included) and
  # SSM parameter value in the account; plan needs neither.
  statement {
    sid           = "DenyOtherObjects"
    effect        = "Deny"
    actions       = ["s3:GetObject*"]
    not_resources = local.own_objects
  }

  statement {
    sid       = "DenyParameterValues"
    effect    = "Deny"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"]
    resources = ["*"]
  }
}

# --- Deploy --------------------------------------------------------------------

data "aws_iam_policy_document" "deploy" {
  # Creating a stack role or changing its permissions requires the boundary.
  statement {
    sid       = "ChangeStackRolesWithinBoundary"
    actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary", "iam:PutRolePolicy", "iam:DeleteRolePolicy"]
    resources = [local.stack_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.stack_boundary.arn]
    }
  }

  statement {
    sid       = "AttachApprovedManagedPolicies"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = [local.stack_role_arn]

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values = [
        "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
        "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.stack_boundary.arn]
    }
  }

  statement {
    sid = "ManageStackRoles"
    actions = [
      "iam:GetRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = [local.stack_role_arn]
  }

  statement {
    sid = "ManageStackInstanceProfiles"
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
    actions   = ["iam:PassRole"]
    resources = [local.stack_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com", "lambda.amazonaws.com", "ssm.amazonaws.com", "config.amazonaws.com"]
    }
  }

  statement {
    sid       = "ReadPolicies"
    actions   = ["iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions"]
    resources = ["*"]
  }
}

# PowerUserAccess would also let the deploy role change the pipeline that
# runs it, its boundary, and every state file. Deny that.
data "aws_iam_policy_document" "deploy_guardrails" {
  statement {
    sid       = "DenyPipelineRoles"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${local.cicd_prefix}-*"]
  }

  statement {
    sid    = "DenyBoundaryChanges"
    effect = "Deny"
    actions = [
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:DeleteRolePermissionsBoundary",
    ]
    resources = [aws_iam_policy.stack_boundary.arn, local.stack_role_arn]
  }

  statement {
    sid     = "DenyPipelineResources"
    effect  = "Deny"
    actions = ["codebuild:*", "codepipeline:*", "codeconnections:*", "codestar-connections:*", "sns:*"]
    resources = concat(
      [local.codebuild_proj_arn, local.codepipeline_arn, "${local.codepipeline_arn}/*", aws_sns_topic.approvals.arn],
      local.connection_arns,
    )
  }

  statement {
    sid       = "DenyKeyAdministration"
    effect    = "Deny"
    actions   = ["kms:PutKeyPolicy", "kms:ScheduleKeyDeletion", "kms:DisableKey", "kms:DisableKeyRotation", "kms:CreateGrant"]
    resources = [aws_kms_key.cicd.arn]
  }

  statement {
    sid    = "DenyBucketSettings"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketVersioning",
      "s3:PutLifecycleConfiguration",
      "s3:PutEncryptionConfiguration",
      "s3:PutBucketPublicAccessBlock",
    ]
    resources = [aws_s3_bucket.artifacts.arn, local.state_bucket_arn]
  }

  statement {
    sid           = "DenyOtherObjects"
    effect        = "Deny"
    actions       = ["s3:GetObject*", "s3:PutObject*", "s3:DeleteObject*"]
    not_resources = local.own_objects
  }
}

# --- Integration tests -------------------------------------------------------------

data "aws_iam_policy_document" "integration" {
  statement {
    sid = "Describe"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeInstanceAttribute",
      "ssm:DescribeInstanceInformation",
      "ssm:GetCommandInvocation",
    ]
    resources = ["*"]
  }

  # Cloud Custodian stops the broker nightly.
  statement {
    sid       = "StartStackInstances"
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
    sid       = "RunShellScript"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:${local.partition}:ssm:${local.region}::document/AWS-RunShellScript"]
  }

  statement {
    sid       = "ReadStackSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.stack_secret_arn]
  }
}

# --- CodePipeline ----------------------------------------------------------------

data "aws_iam_policy_document" "codepipeline_assume_role" {
  statement {
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
  source_policy_documents = [
    data.aws_iam_policy_document.artifacts.json,
    data.aws_iam_policy_document.github_connection.json,
  ]

  statement {
    sid       = "ArtifactBucket"
    actions   = ["s3:GetBucketVersioning", "s3:PutObjectAcl"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid       = "RunBuilds"
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds", "codebuild:StopBuild"]
    resources = [local.codebuild_proj_arn]
  }

  statement {
    sid       = "ApprovalNotifications"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.approvals.arn]
  }
}

resource "aws_iam_role_policy" "codepipeline" {
  name   = "${local.cicd_prefix}-codepipeline"
  role   = aws_iam_role.codepipeline.id
  policy = data.aws_iam_policy_document.codepipeline.json
}
