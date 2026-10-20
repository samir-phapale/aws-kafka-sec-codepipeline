# Network exposure.
package terraform.network

import data.lib.terraform as tf
import rego.v1

public_cidrs := {"0.0.0.0/0", "::/0"}

# NET-001: no inbound traffic from the whole internet. Kafka, the controller
# port and SSH must never be publicly reachable; access is via SSM.
deny contains msg if {
	some rc in tf.resources_of_type("aws_vpc_security_group_ingress_rule")
	some field in ["cidr_ipv4", "cidr_ipv6"]
	rc.change.after[field] in public_cidrs
	msg := sprintf("NET-001 %s: inbound from %s is not allowed", [rc.address, rc.change.after[field]])
}

deny contains msg if {
	some rc in tf.resources_of_type("aws_security_group_rule")
	rc.change.after.type == "ingress"
	some cidr in public_ingress_cidrs(rc.change.after)
	msg := sprintf("NET-001 %s: inbound from %s is not allowed", [rc.address, cidr])
}

deny contains msg if {
	some rc in tf.resources_of_type("aws_security_group")
	some rule in object.get(rc.change.after, "ingress", [])
	some cidr in public_ingress_cidrs(rule)
	msg := sprintf("NET-001 %s: inline ingress from %s is not allowed", [rc.address, cidr])
}

public_ingress_cidrs(rule) := {cidr |
	some field in ["cidr_blocks", "ipv6_cidr_blocks"]
	some cidr in object.get(rule, field, [])
	cidr in public_cidrs
}
