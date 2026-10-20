package terraform.iam_test

import data.lib.testing as t
import data.terraform.iam
import rego.v1

role_policy(document) := t.plan([t.resource("aws_iam_role_policy", "p", {"policy": json.marshal(document)})])

test_full_wildcard_is_denied if {
	doc := {"Statement": [{"Effect": "Allow", "Action": "*", "Resource": "*"}]}
	t.violates(iam.deny, "IAM-001") with input as role_policy(doc)
}

test_wildcard_inside_action_list_is_denied if {
	doc := {"Statement": [{"Effect": "Allow", "Action": ["s3:GetObject", "*"], "Resource": ["*"]}]}
	t.violates(iam.deny, "IAM-001") with input as role_policy(doc)
}

test_single_statement_object_is_checked if {
	doc := {"Statement": {"Effect": "Allow", "Action": "*:*", "Resource": "*"}}
	t.violates(iam.deny, "IAM-001") with input as role_policy(doc)
}

test_scoped_policy_is_allowed if {
	doc := {"Statement": [{"Effect": "Allow", "Action": ["secretsmanager:GetSecretValue"], "Resource": "arn:aws:secretsmanager:us-east-1:111122223333:secret:x"}]}
	count(iam.deny) == 0 with input as role_policy(doc)
}

test_specific_action_on_all_resources_is_allowed if {
	# Some APIs (e.g. config:PutEvaluations) have no resource-level scoping;
	# IAM-001 targets full admin (Action "*"), not every Resource "*".
	doc := {"Statement": [{"Effect": "Allow", "Action": "config:PutEvaluations", "Resource": "*"}]}
	count(iam.deny) == 0 with input as role_policy(doc)
}

test_deny_statement_with_wildcards_is_allowed if {
	doc := {"Statement": [{"Effect": "Deny", "Action": "*", "Resource": "*"}]}
	count(iam.deny) == 0 with input as role_policy(doc)
}

test_policy_unknown_until_apply_is_skipped if {
	count(iam.deny) == 0 with input as t.plan([t.resource("aws_iam_role_policy", "p", {})])
}

test_administrator_access_attachment_is_denied if {
	attachment := {"policy_arn": "arn:aws:iam::aws:policy/AdministratorAccess", "role": "r"}
	t.violates(iam.deny, "IAM-002") with input as t.plan([t.resource("aws_iam_role_policy_attachment", "admin", attachment)])
}

test_managed_service_policy_attachment_is_allowed if {
	attachment := {"policy_arn": "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore", "role": "r"}
	count(iam.deny) == 0 with input as t.plan([t.resource("aws_iam_role_policy_attachment", "ssm", attachment)])
}
