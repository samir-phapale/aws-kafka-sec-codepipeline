# ---------------------------------------------------------------------------
# CodeBuild projects run by the pipelines. Their buildspecs are read from
# the repository revision being built (buildspecs/), so build changes ship
# through the same reviewed main branch as the infrastructure.
# ---------------------------------------------------------------------------

locals {
  pipeline_projects = {
    validate = {
      role        = "validate"
      buildspec   = "buildspecs/validate.yml"
      timeout     = 20
      concurrency = null
    }
    plan = {
      role        = "plan"
      buildspec   = "buildspecs/plan.yml"
      timeout     = 30
      concurrency = null
    }
    apply = {
      role        = "deploy"
      buildspec   = "buildspecs/apply.yml"
      timeout     = 60
      concurrency = 1
    }
    integration = {
      role        = "integration"
      buildspec   = "buildspecs/integration.yml"
      timeout     = 45
      concurrency = null
    }
    destroy = {
      role        = "deploy"
      buildspec   = "buildspecs/destroy.yml"
      timeout     = 60
      concurrency = 1
    }
  }

  log_groups = toset(concat(keys(local.pipeline_projects), ["pr"]))
}

resource "aws_cloudwatch_log_group" "codebuild" {
  for_each = local.log_groups

  name              = "/aws/codebuild/${local.cicd_prefix}-${each.key}"
  retention_in_days = var.log_retention_days
}

resource "aws_codebuild_project" "pipeline" {
  for_each = local.pipeline_projects

  name                   = "${local.cicd_prefix}-${each.key}"
  description            = "${local.cicd_prefix} pipeline: ${each.key}"
  service_role           = aws_iam_role.codebuild[each.value.role].arn
  build_timeout          = each.value.timeout
  concurrent_build_limit = each.value.concurrency
  encryption_key         = aws_kms_key.cicd.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = each.value.buildspec
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = var.codebuild_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    dynamic "environment_variable" {
      for_each = local.build_environment
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild[each.key].name
    }
  }

  depends_on = [aws_iam_role_policy.codebuild]
}

# ---------------------------------------------------------------------------
# Pull request check: a CodeBuild webhook on the GitHub repository that
# reports its result as a status check on the PR.
#
# Only created when pr_allowed_github_user_ids is set, and only PRs opened
# by those GitHub users trigger it. The buildspec is embedded here from main,
# so a PR cannot change the commands; the PR's Terraform code still runs,
# which is why the role is read-only.
# ---------------------------------------------------------------------------

locals {
  pr_check_enabled = length(var.pr_allowed_github_user_ids) > 0
}

resource "aws_codebuild_project" "pr" {
  count = local.pr_check_enabled ? 1 : 0

  name          = "${local.cicd_prefix}-pr"
  description   = "${local.cicd_prefix}: validate and plan pull requests to ${var.branch}"
  service_role  = aws_iam_role.codebuild["pr"].arn
  build_timeout = 30

  encryption_key = aws_kms_key.cicd.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  source {
    type                = "GITHUB"
    location            = "https://github.com/${var.github_repository}.git"
    git_clone_depth     = 1
    report_build_status = true
    buildspec           = file("${path.module}/../buildspecs/pr.yml")

    auth {
      type     = "CODECONNECTIONS"
      resource = aws_codestarconnections_connection.github.arn
    }
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = var.codebuild_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    dynamic "environment_variable" {
      for_each = local.build_environment
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild["pr"].name
    }
  }

  depends_on = [aws_iam_role_policy.codebuild]
}

resource "aws_codebuild_webhook" "pr" {
  count = local.pr_check_enabled ? 1 : 0

  project_name = aws_codebuild_project.pr[0].name
  build_type   = "BUILD"

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "PULL_REQUEST_CREATED, PULL_REQUEST_UPDATED, PULL_REQUEST_REOPENED"
    }

    filter {
      type    = "BASE_REF"
      pattern = "^refs/heads/${var.branch}$"
    }

    filter {
      type    = "ACTOR_ACCOUNT_ID"
      pattern = "^(${join("|", var.pr_allowed_github_user_ids)})$"
    }
  }
}
