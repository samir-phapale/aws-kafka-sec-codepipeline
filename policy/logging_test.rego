package terraform.logging_test

import data.lib.testing as t
import data.terraform.logging
import rego.v1

lambda := t.resource("aws_lambda_function", "rule", {"function_name": "kafka-on-ec2-dev-config-detective"})

log_group(retention) := t.resource("aws_cloudwatch_log_group", "rule", {
	"name": "/aws/lambda/kafka-on-ec2-dev-config-detective",
	"retention_in_days": retention,
})

test_lambda_with_managed_log_group_and_retention_passes if {
	count(logging.deny) == 0 with input as t.plan([lambda, log_group(14)])
}

test_log_group_that_never_expires_is_denied if {
	t.violates(logging.deny, "LOG-001") with input as t.plan([lambda, log_group(0)])
}

test_log_group_without_retention_is_denied if {
	group := t.resource("aws_cloudwatch_log_group", "rule", {"name": "/aws/lambda/kafka-on-ec2-dev-config-detective"})
	t.violates(logging.deny, "LOG-001") with input as t.plan([lambda, group])
}

test_lambda_without_managed_log_group_is_denied if {
	t.violates(logging.deny, "LOG-002") with input as t.plan([lambda])
}
