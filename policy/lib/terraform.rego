# Helpers for reading a Terraform plan (`terraform show -json tfplan`).
package lib.terraform

import rego.v1

# Managed resources that will exist after this plan: created, updated,
# replaced or unchanged. Policies therefore check the whole stack on every
# run, not only the resources a change happens to touch.
resources contains rc if {
	some rc in input.resource_changes
	rc.mode == "managed"
	rc.change.actions != ["delete"]
}

resources_of_type(resource_type) := {rc | some rc in resources; rc.type == resource_type}

# "module.a.module.b." for a resource found at `path` inside input.configuration
# (walk() paths look like [root_module, module_calls, a, module, resources, 0]).
module_prefix(path) := concat("", [sprintf("module.%s.", [path[i + 1]]) |
	some i
	path[i] == "module_calls"
])
