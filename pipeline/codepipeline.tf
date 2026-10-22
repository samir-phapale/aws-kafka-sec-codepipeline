# Both pipelines apply exactly the tfplan that was approved; Terraform rejects
# it if the state changed in between. CodePipeline runs every new pipeline
# once; both stop at Approve (reject the destroy one).

resource "aws_codepipeline" "deploy" {
  name           = "${local.cicd_prefix}-deploy"
  role_arn       = aws_iam_role.codepipeline.arn
  pipeline_type  = "V2"
  execution_mode = "QUEUED"

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"

    encryption_key {
      id   = aws_kms_key.cicd.arn
      type = "KMS"
    }
  }

  # Pushes that only change Markdown files do not start a run.
  trigger {
    provider_type = "CodeStarSourceConnection"

    git_configuration {
      source_action_name = "Source"

      push {
        branches {
          includes = [var.branch]
        }

        file_paths {
          excludes = ["*.md", "**/*.md"]
        }
      }
    }
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source"]

      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.github.arn
        FullRepositoryId = var.github_repository
        BranchName       = var.branch
        DetectChanges    = "false"
      }
    }
  }

  stage {
    name = "Validate"

    action {
      name            = "Validate"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source"]

      configuration = {
        ProjectName = aws_codebuild_project.this["validate"].name
      }
    }
  }

  stage {
    name = "Plan"

    action {
      name             = "Plan"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source"]
      output_artifacts = ["plan"]

      configuration = {
        ProjectName = aws_codebuild_project.this["plan"].name
      }
    }
  }

  stage {
    name = "Approve"

    action {
      name     = "Approve"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"

      configuration = {
        NotificationArn = aws_sns_topic.approvals.arn
        CustomData      = "Review the Plan stage log before approving: approval applies exactly that plan."
      }
    }
  }

  stage {
    name = "Apply"

    action {
      name            = "Apply"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["plan"]
      namespace       = "Apply"

      configuration = {
        ProjectName = aws_codebuild_project.this["apply"].name
      }
    }
  }

  stage {
    name = "Integration"

    action {
      name            = "KafkaEndToEnd"
      category        = "Test"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source"]

      configuration = {
        ProjectName = aws_codebuild_project.this["integration"].name
        EnvironmentVariables = jsonencode([
          { name = "KAFKA_INSTANCE_ID", value = "#{Apply.INSTANCE_ID}", type = "PLAINTEXT" },
          { name = "KAFKA_TOPIC_NAME", value = "#{Apply.TOPIC_NAME}", type = "PLAINTEXT" },
          { name = "KAFKA_SECRET_ARN", value = "#{Apply.SECRET_ARN}", type = "PLAINTEXT" },
        ])
      }
    }
  }

  depends_on = [aws_iam_role_policy.codepipeline]
}

# Started by hand with "Release change".
resource "aws_codepipeline" "destroy" {
  name           = "${local.cicd_prefix}-destroy"
  role_arn       = aws_iam_role.codepipeline.arn
  pipeline_type  = "V2"
  execution_mode = "QUEUED"

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"

    encryption_key {
      id   = aws_kms_key.cicd.arn
      type = "KMS"
    }
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source"]

      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.github.arn
        FullRepositoryId = var.github_repository
        BranchName       = var.branch
        DetectChanges    = "false"
      }
    }
  }

  stage {
    name = "PlanDestroy"

    action {
      name             = "PlanDestroy"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source"]
      output_artifacts = ["plan"]

      configuration = {
        ProjectName          = aws_codebuild_project.this["plan"].name
        EnvironmentVariables = jsonencode([{ name = "TF_PLAN_ARGS", value = "-destroy", type = "PLAINTEXT" }])
      }
    }
  }

  stage {
    name = "Approve"

    action {
      name     = "Approve"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"

      configuration = {
        NotificationArn = aws_sns_topic.approvals.arn
        CustomData      = "DESTROY: review the PlanDestroy stage log. Approval deletes everything in it, including the Kafka broker."
      }
    }
  }

  stage {
    name = "Destroy"

    action {
      name            = "Destroy"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["plan"]

      configuration = {
        ProjectName = aws_codebuild_project.this["destroy"].name
      }
    }
  }

  depends_on = [aws_iam_role_policy.codepipeline]
}
