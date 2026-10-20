# EC2 hardening and cost guardrails.
package terraform.ec2

import data.lib.terraform as tf
import rego.v1

allowed_instance_families := {"t3", "t3a"}

# EC2-001: IMDSv2 must be required, so instance credentials cannot be stolen
# through the instance metadata service with a simple SSRF.
deny contains msg if {
	some rc in tf.resources_of_type("aws_instance")
	not imdsv2_required(rc.change.after)
	msg := sprintf("EC2-001 %s: IMDSv2 must be required (metadata_options { http_tokens = \"required\" })", [rc.address])
}

imdsv2_required(after) if after.metadata_options[0].http_tokens == "required"

# EC2-002: root and data volumes must be encrypted at rest. The root volume
# must be declared explicitly, so encryption never depends on account defaults.
deny contains msg if {
	some rc in tf.resources_of_type("aws_instance")
	count(object.get(rc.change.after, "root_block_device", [])) == 0
	msg := sprintf("EC2-002 %s: declare root_block_device with encrypted = true", [rc.address])
}

deny contains msg if {
	some rc in tf.resources_of_type("aws_instance")
	some device in ["root_block_device", "ebs_block_device"]
	some volume in object.get(rc.change.after, device, [])
	not volume.encrypted == true
	msg := sprintf("EC2-002 %s: %s must be encrypted", [rc.address, device])
}

deny contains msg if {
	some rc in tf.resources_of_type("aws_ebs_volume")
	not rc.change.after.encrypted == true
	msg := sprintf("EC2-002 %s: EBS volume must be encrypted", [rc.address])
}

# EC2-003: only approved burstable instance families, to keep lab cost bounded.
deny contains msg if {
	some rc in tf.resources_of_type("aws_instance")
	family := split(rc.change.after.instance_type, ".")[0]
	not family in allowed_instance_families
	msg := sprintf("EC2-003 %s: instance type %s is not allowed (allowed families: %v)", [rc.address, rc.change.after.instance_type, sort(allowed_instance_families)])
}
