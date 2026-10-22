data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = var.aws_region

  # The deploy role may manage stack_prefix-* resources only; that pattern
  # never matches the pipeline's own cicd_prefix-* resources.
  stack_prefix = "${var.project_name}-${var.environment}"
  cicd_prefix  = "${var.project_name}-cicd-${var.environment}"

  codebuild_image = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
  console_url     = "https://${local.region}.console.aws.amazon.com/codesuite/codepipeline/pipelines"

  stack_role_arn     = "arn:${local.partition}:iam::${local.account_id}:role/${local.stack_prefix}-*"
  stack_secret_arn   = "arn:${local.partition}:secretsmanager:${local.region}:${local.account_id}:secret:${local.stack_prefix}/*"
  state_bucket_arn   = "arn:${local.partition}:s3:::${var.tf_state_bucket}"
  state_object_arn   = "${local.state_bucket_arn}/${var.tf_state_key}"
  state_lock_arn     = "${local.state_bucket_arn}/${var.tf_state_key}.tflock"
  codebuild_logs_arn = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/codebuild/${local.cicd_prefix}-*"
  codebuild_proj_arn = "arn:${local.partition}:codebuild:${local.region}:${local.account_id}:project/${local.cicd_prefix}-*"
  codepipeline_arn   = "arn:${local.partition}:codepipeline:${local.region}:${local.account_id}:${local.cicd_prefix}-*"
}

# Created as PENDING; complete it once in the console (Settings > Connections).
resource "aws_codestarconnections_connection" "github" {
  name          = substr("${local.cicd_prefix}-github", 0, 32)
  provider_type = "GitHub"
}
