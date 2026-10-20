# Logs must exist and must not be kept forever.
package terraform.logging

import data.lib.terraform as tf
import rego.v1

# LOG-001: log groups need a retention period (0 or unset means "never expire").
deny contains msg if {
	some rc in tf.resources_of_type("aws_cloudwatch_log_group")
	not object.get(rc.change.after, "retention_in_days", 0) > 0
	msg := sprintf("LOG-001 %s: set retention_in_days", [rc.address])
}

# LOG-002: every Lambda has its log group managed in code (so LOG-001 applies
# to it), instead of one auto-created by Lambda with no retention.
deny contains msg if {
	some rc in tf.resources_of_type("aws_lambda_function")
	log_group := sprintf("/aws/lambda/%s", [rc.change.after.function_name])
	not log_group in managed_log_groups
	msg := sprintf("LOG-002 %s: manage its log group %s in Terraform", [rc.address, log_group])
}

managed_log_groups := {rc.change.after.name | some rc in tf.resources_of_type("aws_cloudwatch_log_group")}
