package terraform.secrets_test

import data.terraform.secrets
import rego.v1

secret_version(secret_string_expression) := {
	"resource_changes": [],
	"configuration": {"root_module": {"module_calls": {"secrets_manager": {"module": {"resources": [{
		"address": "aws_secretsmanager_secret_version.phase3",
		"type": "aws_secretsmanager_secret_version",
		"expressions": {"secret_string": secret_string_expression},
	}]}}}}},
}

test_hard_coded_secret_is_denied_with_module_address if {
	msgs := secrets.deny with input as secret_version({"constant_value": "Sup3rS3cret!"})
	some msg in msgs
	startswith(msg, "SEC-001 module.secrets_manager.aws_secretsmanager_secret_version.phase3")
}

test_generated_secret_is_allowed if {
	expression := {"references": ["random_password.demo_password.result", "random_password.demo_password"]}
	count(secrets.deny) == 0 with input as secret_version(expression)
}

test_denial_message_never_contains_the_value if {
	msgs := secrets.deny with input as secret_version({"constant_value": "Sup3rS3cret!"})
	every msg in msgs {
		not contains(msg, "Sup3rS3cret!")
	}
}
