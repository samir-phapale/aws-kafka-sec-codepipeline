# Least privilege.
package terraform.iam

import data.lib.terraform as tf
import rego.v1

inline_policy_types := {"aws_iam_role_policy", "aws_iam_policy", "aws_iam_user_policy", "aws_iam_group_policy"}

# IAM-001: no statement may allow every action on every resource.
# Policies whose JSON is only known after apply cannot be checked at plan time.
deny contains msg if {
	some rc in tf.resources
	rc.type in inline_policy_types
	is_string(rc.change.after.policy)
	some statement in statements(json.unmarshal(rc.change.after.policy))
	statement.Effect == "Allow"
	some action in as_array(statement.Action)
	action in {"*", "*:*"}
	"*" in as_array(statement.Resource)
	msg := sprintf("IAM-001 %s: statement allows Action \"*\" on Resource \"*\"", [rc.address])
}

# IAM-002: no AdministratorAccess attachments.
deny contains msg if {
	some rc in tf.resources
	rc.type in {"aws_iam_role_policy_attachment", "aws_iam_user_policy_attachment", "aws_iam_group_policy_attachment"}
	endswith(rc.change.after.policy_arn, ":policy/AdministratorAccess")
	msg := sprintf("IAM-002 %s: AdministratorAccess must not be attached", [rc.address])
}

statements(document) := document.Statement if is_array(document.Statement)

statements(document) := [document.Statement] if is_object(document.Statement)

as_array(value) := value if is_array(value)

as_array(value) := [value] if is_string(value)
