# Builders for policy unit tests (used by the *_test.rego files).
package lib.testing

import rego.v1

plan(resources) := {"resource_changes": resources, "configuration": {}}

resource(resource_type, name, after) := resource_with_actions(resource_type, name, after, ["create"])

resource_with_actions(resource_type, name, after, actions) := {
	"address": sprintf("%s.%s", [resource_type, name]),
	"mode": "managed",
	"type": resource_type,
	"name": name,
	"change": {"actions": actions, "after": after},
}

# True when some message produced by a policy starts with the rule ID.
violates(messages, rule_id) if {
	some msg in messages
	startswith(msg, rule_id)
}
