output "github_connection_arn" {
  description = "CodeConnections connection to GitHub"
  value       = aws_codestarconnections_connection.github.arn
}

output "github_connection_status" {
  description = "PENDING until the connection is completed in the console; the pipelines cannot fetch source before it is AVAILABLE"
  value       = aws_codestarconnections_connection.github.connection_status
}

output "deploy_pipeline_url" {
  description = "Console URL of the deploy pipeline"
  value       = "${local.console_pipeline_ui}/${aws_codepipeline.this["deploy"].name}/view?region=${local.region}"
}

output "destroy_pipeline_url" {
  description = "Console URL of the destroy pipeline (start it with Release change)"
  value       = "${local.console_pipeline_ui}/${aws_codepipeline.this["destroy"].name}/view?region=${local.region}"
}

output "artifact_bucket" {
  description = "S3 bucket holding pipeline artifacts (KMS encrypted)"
  value       = aws_s3_bucket.artifacts.bucket
}

output "notification_topic_arn" {
  description = "SNS topic for approval requests and pipeline results"
  value       = aws_sns_topic.cicd.arn
}

output "pr_check_project" {
  description = "CodeBuild project checking pull requests (null when pr_allowed_github_user_ids is empty)"
  value       = local.pr_check_enabled ? aws_codebuild_project.pr[0].name : null
}

output "codebuild_role_arns" {
  description = "Service role of each CodeBuild job"
  value       = { for k, role in aws_iam_role.codebuild : k => role.arn }
}
