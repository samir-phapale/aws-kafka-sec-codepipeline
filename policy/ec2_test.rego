package terraform.ec2_test

import data.lib.testing as t
import data.terraform.ec2
import rego.v1

compliant_instance := {
	"instance_type": "t3.medium",
	"metadata_options": [{"http_tokens": "required"}],
	"root_block_device": [{"encrypted": true}],
	"ebs_block_device": [],
}

instance(overrides) := t.plan([t.resource("aws_instance", "kafka", object.union(compliant_instance, overrides))])

test_compliant_instance_passes if {
	count(ec2.deny) == 0 with input as instance({})
}

test_imdsv1_allowed_is_denied if {
	t.violates(ec2.deny, "EC2-001") with input as instance({"metadata_options": [{"http_tokens": "optional"}]})
}

test_missing_metadata_options_is_denied if {
	t.violates(ec2.deny, "EC2-001") with input as instance({"metadata_options": []})
}

test_unencrypted_root_volume_is_denied if {
	t.violates(ec2.deny, "EC2-002") with input as instance({"root_block_device": [{"encrypted": false}]})
}

test_undeclared_root_volume_is_denied if {
	t.violates(ec2.deny, "EC2-002") with input as instance({"root_block_device": []})
}

test_unencrypted_data_volume_is_denied if {
	t.violates(ec2.deny, "EC2-002") with input as instance({"ebs_block_device": [{"encrypted": false}]})
}

test_unencrypted_ebs_volume_resource_is_denied if {
	t.violates(ec2.deny, "EC2-002") with input as t.plan([t.resource("aws_ebs_volume", "data", {"encrypted": false})])
}

test_disallowed_instance_family_is_denied if {
	t.violates(ec2.deny, "EC2-003") with input as instance({"instance_type": "m5.4xlarge"})
}

test_t3a_family_is_allowed if {
	count(ec2.deny) == 0 with input as instance({"instance_type": "t3a.large"})
}

test_instance_being_deleted_is_ignored if {
	deleted := t.resource_with_actions("aws_instance", "old", {"instance_type": "m5.4xlarge"}, ["delete"])
	count(ec2.deny) == 0 with input as t.plan([deleted])
}
