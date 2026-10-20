# Secrets must never be written into code.
package terraform.secrets

import data.lib.terraform as tf
import rego.v1

# SEC-001: a Secrets Manager secret value must be generated (for example by
# random_password), never a literal in the Terraform code. This inspects the
# configuration section of the plan - how the value is written - so the check
# never needs to read the secret value itself.
deny contains msg if {
	walk(input.configuration, [path, resource])
	resource.type == "aws_secretsmanager_secret_version"
	resource.expressions.secret_string.constant_value
	msg := sprintf("SEC-001 %s%s: secret_string is a hard-coded literal; generate it instead (e.g. random_password)", [tf.module_prefix(path), resource.address])
}
