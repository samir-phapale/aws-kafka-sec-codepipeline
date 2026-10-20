# ---------------------------------------------------------------------------
# Pipelines
#
# deploy:  push to main -> Source -> Validate -> Plan -> Approve -> Apply -> Integration
# destroy: manual "Release change" -> Source -> PlanDestroy -> Approve -> Destroy
#
# Both apply exactly the tfplan the approver reviewed (it travels as the
# "plan" artifact); Terraform rejects it if the state changed in between.
# QUEUED execution mode means runs never overlap or supersede each other.
#
# Note: CodePipeline starts one execution when a pipeline is created. Both
# pipelines stop at their Approve stage, so nothing changes until approved.
# ---------------------------------------------------------------------------

locals {
  pipeline_names = {
    deploy  = "${local.cicd_prefix}-deploy"
    destroy = "${local.cicd_prefix}-destroy"
  }

  pipelines = {
    deploy = {
      detect_changes = true
      stages = [
        {
          name = "Validate"
          action = {
            name      = "Validate"
            category  = "Build"
            provider  = "CodeBuild"
            inputs    = ["source"]
            outputs   = []
            namespace = null
            configuration = {
              ProjectName = aws_codebuild_project.pipeline["validate"].name
            }
          }
        },
        {
          name = "Plan"
          action = {
            name      = "Plan"
            category  = "Build"
            provider  = "CodeBuild"
            inputs    = ["source"]
            outputs   = ["plan"]
            namespace = null
            configuration = {
              ProjectName = aws_codebuild_project.pipeline["plan"].name
            }
          }
        },
        {
          name = "Approve"
          action = {
            name      = "ApproveApply"
            category  = "Approval"
            provider  = "Manual"
            inputs    = []
            outputs   = []
            namespace = null
            configuration = {
              NotificationArn    = aws_sns_topic.cicd.arn
              ExternalEntityLink = "${local.console_pipeline_ui}/${local.pipeline_names.deploy}/view?region=${local.region}"
              CustomData         = "Review the terraform plan in the Plan stage's build log (and that the OPA policy check passed) before approving. Approval applies exactly that plan to ${local.stack_prefix}."
            }
          }
        },
        {
          name = "Apply"
          action = {
            name      = "Apply"
            category  = "Build"
            provider  = "CodeBuild"
            inputs    = ["plan"]
            outputs   = []
            namespace = "ApplyVars"
            configuration = {
              ProjectName = aws_codebuild_project.pipeline["apply"].name
            }
          }
        },
        {
          name = "Integration"
          action = {
            name      = "KafkaEndToEnd"
            category  = "Test"
            provider  = "CodeBuild"
            inputs    = ["source"]
            outputs   = []
            namespace = null
            configuration = {
              ProjectName = aws_codebuild_project.pipeline["integration"].name
              EnvironmentVariables = jsonencode([
                { name = "KAFKA_INSTANCE_ID", value = "#{ApplyVars.INSTANCE_ID}", type = "PLAINTEXT" },
                { name = "KAFKA_TOPIC_NAME", value = "#{ApplyVars.TOPIC_NAME}", type = "PLAINTEXT" },
                { name = "KAFKA_SECRET_ARN", value = "#{ApplyVars.SECRET_ARN}", type = "PLAINTEXT" },
              ])
            }
          }
        },
      ]
    }

    destroy = {
      # Runs only when started by hand ("Release change").
      detect_changes = false
      stages = [
        {
          name = "PlanDestroy"
          action = {
            name      = "PlanDestroy"
            category  = "Build"
            provider  = "CodeBuild"
            inputs    = ["source"]
            outputs   = ["plan"]
            namespace = null
            configuration = {
              ProjectName = aws_codebuild_project.pipeline["plan"].name
              EnvironmentVariables = jsonencode([
                { name = "TF_PLAN_ARGS", value = "-destroy", type = "PLAINTEXT" },
              ])
            }
          }
        },
        {
          name = "Approve"
          action = {
            name      = "ApproveDestroy"
            category  = "Approval"
            provider  = "Manual"
            inputs    = []
            outputs   = []
            namespace = null
            configuration = {
              NotificationArn    = aws_sns_topic.cicd.arn
              ExternalEntityLink = "${local.console_pipeline_ui}/${local.pipeline_names.destroy}/view?region=${local.region}"
              CustomData         = "DESTROY ${local.stack_prefix}: review the destroy plan in the PlanDestroy stage's build log. Approval deletes every resource in it, including the Kafka broker and its data."
            }
          }
        },
        {
          name = "Destroy"
          action = {
            name      = "Destroy"
            category  = "Build"
            provider  = "CodeBuild"
            inputs    = ["plan"]
            outputs   = []
            namespace = null
            configuration = {
              ProjectName = aws_codebuild_project.pipeline["destroy"].name
            }
          }
        },
      ]
    }
  }
}

resource "aws_codepipeline" "this" {
  for_each = local.pipelines

  name           = local.pipeline_names[each.key]
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
        ConnectionArn        = aws_codestarconnections_connection.github.arn
        FullRepositoryId     = var.github_repository
        BranchName           = var.branch
        DetectChanges        = tostring(each.value.detect_changes)
        OutputArtifactFormat = "CODE_ZIP"
      }
    }
  }

  dynamic "stage" {
    for_each = each.value.stages

    content {
      name = stage.value.name

      action {
        name             = stage.value.action.name
        category         = stage.value.action.category
        owner            = "AWS"
        provider         = stage.value.action.provider
        version          = "1"
        input_artifacts  = stage.value.action.inputs
        output_artifacts = stage.value.action.outputs
        namespace        = stage.value.action.namespace
        configuration    = stage.value.action.configuration
      }
    }
  }

  depends_on = [aws_iam_role_policy.codepipeline]
}
