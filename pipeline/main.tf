data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = var.aws_region

  # Resources of the Kafka stack: what the deploy role may manage.
  stack_prefix = "${var.project_name}-${var.environment}"
  # Resources of this pipeline. Deliberately NOT matched by "<stack_prefix>-*",
  # so the deploy role can never modify the pipeline that runs it.
  cicd_prefix = "${var.project_name}-cicd-${var.environment}"

  stack_secret_arn    = "arn:${local.partition}:secretsmanager:${local.region}:${local.account_id}:secret:${local.stack_prefix}/*"
  state_bucket_arn    = "arn:${local.partition}:s3:::${var.tf_state_bucket}"
  state_object_arn    = "${local.state_bucket_arn}/${var.tf_state_key}"
  state_lock_arn      = "${local.state_bucket_arn}/${var.tf_state_key}.tflock"
  codebuild_logs_arn  = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/codebuild/${local.cicd_prefix}-*"
  codebuild_proj_arn  = "arn:${local.partition}:codebuild:${local.region}:${local.account_id}:project/${local.cicd_prefix}-*"
  codepipeline_arn    = "arn:${local.partition}:codepipeline:${local.region}:${local.account_id}:${local.cicd_prefix}-*"
  console_pipeline_ui = "https://${local.region}.console.aws.amazon.com/codesuite/codepipeline/pipelines"

  # Environment shared by every CodeBuild project.
  build_environment = {
    TF_STATE_BUCKET   = var.tf_state_bucket
    TF_STATE_KEY      = var.tf_state_key
    TERRAFORM_VERSION = var.terraform_version
    CONFTEST_VERSION  = var.conftest_version
  }
}

# ---------------------------------------------------------------------------
# GitHub connection (CodeConnections)
#
# Created in PENDING state. It must be completed once in the console
# (Developer Tools -> Settings -> Connections -> Update pending connection),
# which installs the AWS Connector GitHub app on the repository.
# ---------------------------------------------------------------------------

resource "aws_codestarconnections_connection" "github" {
  name          = substr("${local.cicd_prefix}-github", 0, 32)
  provider_type = "GitHub"
}
