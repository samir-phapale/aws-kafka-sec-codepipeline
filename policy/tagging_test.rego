package terraform.tagging_test

import data.lib.testing as t
import data.terraform.tagging
import rego.v1

all_tags := {"Project": "kafka-on-ec2", "Environment": "dev", "ManagedBy": "terraform", "Phase": "phase-3"}

test_resource_with_required_tags_passes if {
	count(tagging.deny) == 0 with input as t.plan([t.resource("aws_vpc", "this", {"tags_all": all_tags})])
}

test_missing_tag_is_denied_and_named if {
	tags := object.remove(all_tags, ["ManagedBy"])
	msgs := tagging.deny with input as t.plan([t.resource("aws_vpc", "this", {"tags_all": tags})])
	some msg in msgs
	startswith(msg, "TAG-001")
	contains(msg, "ManagedBy")
}

test_untagged_resource_is_denied if {
	t.violates(tagging.deny, "TAG-001") with input as t.plan([t.resource("aws_vpc", "this", {"tags_all": {}})])
}

test_resource_type_without_tags_is_ignored if {
	count(tagging.deny) == 0 with input as t.plan([t.resource("aws_lambda_permission", "config", {"action": "lambda:InvokeFunction"})])
}
