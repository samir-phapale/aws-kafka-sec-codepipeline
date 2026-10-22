output "github_connection_status" {
  description = "Must be AVAILABLE before the pipelines can run"
  value       = aws_codestarconnections_connection.github.connection_status
}

output "deploy_pipeline_url" {
  value = "${local.console_url}/${aws_codepipeline.deploy.name}/view?region=${local.region}"
}

output "destroy_pipeline_url" {
  value = "${local.console_url}/${aws_codepipeline.destroy.name}/view?region=${local.region}"
}

output "stack_boundary_arn" {
  value = aws_iam_policy.stack_boundary.arn
}
