locals {
  # Project name => service role. Buildspecs come from buildspecs/<name>.yml.
  projects = {
    validate    = "validate"
    plan        = "plan"
    apply       = "deploy"
    integration = "integration"
    destroy     = "deploy"
  }
}

resource "aws_cloudwatch_log_group" "codebuild" {
  for_each = toset(concat(keys(local.projects), ["pr"]))

  name              = "/aws/codebuild/${local.cicd_prefix}-${each.key}"
  retention_in_days = 30
}

resource "aws_codebuild_project" "this" {
  for_each = local.projects

  name                   = "${local.cicd_prefix}-${each.key}"
  service_role           = aws_iam_role.codebuild[each.value].arn
  build_timeout          = 60
  concurrent_build_limit = each.value == "deploy" ? 1 : null
  encryption_key         = aws_kms_key.cicd.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspecs/${each.key}.yml"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = local.codebuild_image
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "TF_STATE_BUCKET"
      value = var.tf_state_bucket
    }

    environment_variable {
      name  = "TF_STATE_KEY"
      value = var.tf_state_key
    }

    environment_variable {
      name  = "TERRAFORM_VERSION"
      value = var.terraform_version
    }

    environment_variable {
      name  = "CONFTEST_VERSION"
      value = var.conftest_version
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild[each.key].name
    }
  }

  depends_on = [aws_iam_role_policy.codebuild]
}

# PR check: runs buildspecs/validate.yml (embedded from main) on every PR from
# an allow-listed GitHub user and reports the result on the PR. It runs the PR
# author's code, so its role has no AWS access beyond its own logs.
resource "aws_codebuild_project" "pr" {
  count = length(var.pr_allowed_github_user_ids) > 0 ? 1 : 0

  name          = "${local.cicd_prefix}-pr"
  service_role  = aws_iam_role.codebuild["pr"].arn
  build_timeout = 20

  artifacts {
    type = "NO_ARTIFACTS"
  }

  source {
    type                = "GITHUB"
    location            = "https://github.com/${var.github_repository}.git"
    git_clone_depth     = 1
    report_build_status = true
    buildspec           = file("${path.module}/../buildspecs/validate.yml")

    auth {
      type     = "CODECONNECTIONS"
      resource = aws_codestarconnections_connection.github.arn
    }
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = local.codebuild_image
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "TERRAFORM_VERSION"
      value = var.terraform_version
    }

    environment_variable {
      name  = "CONFTEST_VERSION"
      value = var.conftest_version
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
  count = length(aws_codebuild_project.pr)

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
