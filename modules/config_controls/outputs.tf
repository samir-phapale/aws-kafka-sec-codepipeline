output "conformance_pack_name" {
  description = "Name of the Phase 3 conformance pack (AWS Config appends a suffix to the rule names inside it)."
  value       = aws_config_conformance_pack.s3_security.name
}

output "detective_lambda_name" {
  description = "Name of the detective custom rule Lambda."
  value       = aws_lambda_function.rule["detective"].function_name
}

output "reactive_lambda_name" {
  description = "Name of the reactive custom rule Lambda."
  value       = aws_lambda_function.rule["reactive"].function_name
}

output "remediation_document_name" {
  description = "Name of the custom SSM Automation document that remediates the reactive rule."
  value       = aws_ssm_document.s3_public_access_remediation.name
}
