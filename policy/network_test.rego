package terraform.network_test

import data.lib.testing as t
import data.terraform.network
import rego.v1

ingress_rule(after) := t.plan([t.resource("aws_vpc_security_group_ingress_rule", "rule", after)])

test_ingress_from_internet_is_denied if {
	t.violates(network.deny, "NET-001") with input as ingress_rule({"cidr_ipv4": "0.0.0.0/0", "cidr_ipv6": null})
}

test_ipv6_ingress_from_internet_is_denied if {
	t.violates(network.deny, "NET-001") with input as ingress_rule({"cidr_ipv4": null, "cidr_ipv6": "::/0"})
}

test_ingress_from_vpc_cidr_is_allowed if {
	count(network.deny) == 0 with input as ingress_rule({"cidr_ipv4": "10.0.0.0/16", "cidr_ipv6": null})
}

test_ingress_from_security_group_is_allowed if {
	count(network.deny) == 0 with input as ingress_rule({"cidr_ipv4": null, "cidr_ipv6": null, "referenced_security_group_id": "sg-123"})
}

test_legacy_ingress_rule_from_internet_is_denied if {
	rule := {"type": "ingress", "cidr_blocks": ["0.0.0.0/0"], "ipv6_cidr_blocks": []}
	t.violates(network.deny, "NET-001") with input as t.plan([t.resource("aws_security_group_rule", "ssh", rule)])
}

test_legacy_egress_rule_to_internet_is_allowed if {
	rule := {"type": "egress", "cidr_blocks": ["0.0.0.0/0"], "ipv6_cidr_blocks": []}
	count(network.deny) == 0 with input as t.plan([t.resource("aws_security_group_rule", "out", rule)])
}

test_inline_ingress_from_internet_is_denied if {
	sg := {"ingress": [{"cidr_blocks": ["0.0.0.0/0"]}], "egress": []}
	t.violates(network.deny, "NET-001") with input as t.plan([t.resource("aws_security_group", "sg", sg)])
}

test_inline_egress_to_internet_is_allowed if {
	sg := {"ingress": [], "egress": [{"cidr_blocks": ["0.0.0.0/0"]}]}
	count(network.deny) == 0 with input as t.plan([t.resource("aws_security_group", "sg", sg)])
}
