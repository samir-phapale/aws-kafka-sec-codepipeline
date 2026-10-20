# Ownership and cost-allocation tags.
package terraform.tagging

import data.lib.terraform as tf
import rego.v1

required_tags := {"Project", "Environment", "ManagedBy"}

# TAG-001: every taggable resource carries the required tags. tags_all
# includes the provider's default_tags, which is how this stack sets them.
deny contains msg if {
	some rc in tf.resources
	tags := rc.change.after.tags_all
	is_object(tags)
	missing := required_tags - {key | some key, _ in tags}
	count(missing) > 0
	msg := sprintf("TAG-001 %s: missing required tags %v", [rc.address, sort(missing)])
}
