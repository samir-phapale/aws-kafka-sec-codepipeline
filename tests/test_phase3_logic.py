import importlib.util
import json
from pathlib import Path
from unittest.mock import Mock

import pytest
from botocore.exceptions import ClientError

ROOT = Path(__file__).resolve().parents[1]
DETECTIVE = ROOT / "modules/config_controls/lambda/detective/handler.py"
REACTIVE = ROOT / "modules/config_controls/lambda/reactive/handler.py"

TAG_KEY, TAG_VALUE = "Phase3Scope", "kafka-on-ec2-dev"
RULE_PARAMETERS = json.dumps({"TagKey": TAG_KEY, "TagValue": TAG_VALUE})


def load_handler(path: Path, **clients):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for name, client in clients.items():
        setattr(module, name, client)
    return module


def client_error(code: str, operation: str = "Op"):
    return ClientError({"Error": {"Code": code, "Message": code}}, operation)


def put_evaluations(config: Mock):
    return [
        evaluation
        for call in config.put_evaluations.call_args_list
        for evaluation in call.kwargs["Evaluations"]
    ]


# ---------------------------------------------------------------------------
# Detective: periodic S3 versioning rule
# ---------------------------------------------------------------------------


@pytest.fixture
def detective(monkeypatch):
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    s3, config, tagging = Mock(), Mock(), Mock()
    s3.get_bucket_location.return_value = {"LocationConstraint": None}
    module = load_handler(DETECTIVE, s3=s3, config=config, tagging=tagging)

    def tagged(*names):
        tagging.get_paginator.return_value.paginate.return_value = [
            {"ResourceTagMappingList": [{"ResourceARN": f"arn:aws:s3:::{n}"} for n in names]}
        ]

    return module, s3, config, tagging, tagged


def detective_event():
    return {"resultToken": "token", "ruleParameters": RULE_PARAMETERS}


def test_detective_marks_versioned_bucket_compliant(detective):
    module, s3, config, _, tagged = detective
    tagged("versioned-bucket")
    s3.get_bucket_versioning.return_value = {"Status": "Enabled"}

    assert module.lambda_handler(detective_event(), None) == {"evaluated": 1}
    assert put_evaluations(config)[0]["ComplianceType"] == "COMPLIANT"


@pytest.mark.parametrize("versioning", [{}, {"Status": "Suspended"}])
def test_detective_marks_unversioned_bucket_non_compliant(detective, versioning):
    module, s3, config, _, tagged = detective
    tagged("unversioned-bucket")
    s3.get_bucket_versioning.return_value = versioning

    module.lambda_handler(detective_event(), None)

    assert put_evaluations(config)[0]["ComplianceType"] == "NON_COMPLIANT"


def test_detective_only_queries_buckets_with_scope_tag(detective):
    module, _, _, tagging, tagged = detective
    tagged()

    assert module.lambda_handler(detective_event(), None) == {"evaluated": 0}
    tagging.get_paginator.return_value.paginate.assert_called_once_with(
        TagFilters=[{"Key": TAG_KEY, "Values": [TAG_VALUE]}],
        ResourceTypeFilters=["s3"],
    )


def test_detective_skips_buckets_in_other_regions(detective):
    module, s3, config, _, tagged = detective
    tagged("eu-bucket")
    s3.get_bucket_location.return_value = {"LocationConstraint": "eu-west-1"}

    assert module.lambda_handler(detective_event(), None) == {"evaluated": 0}
    s3.get_bucket_versioning.assert_not_called()
    config.put_evaluations.assert_not_called()


def test_detective_skips_bucket_deleted_after_tag_lookup(detective):
    module, s3, _, _, tagged = detective
    tagged("gone-bucket")
    s3.get_bucket_location.side_effect = client_error("NoSuchBucket")

    assert module.lambda_handler(detective_event(), None) == {"evaluated": 0}


def test_detective_batches_put_evaluations_by_100(detective):
    module, s3, config, _, tagged = detective
    tagged(*[f"bucket-{i}" for i in range(150)])
    s3.get_bucket_versioning.return_value = {"Status": "Enabled"}

    module.lambda_handler(detective_event(), None)

    assert [len(c.kwargs["Evaluations"]) for c in config.put_evaluations.call_args_list] == [100, 50]


def test_detective_requires_scope_tag_parameters(detective):
    module = detective[0]
    with pytest.raises(ValueError):
        module.lambda_handler({"resultToken": "token"}, None)


# ---------------------------------------------------------------------------
# Reactive: change-triggered S3 Public Access Block rule
# ---------------------------------------------------------------------------

ALL_BLOCKED = {
    "BlockPublicAcls": True,
    "BlockPublicPolicy": True,
    "IgnorePublicAcls": True,
    "RestrictPublicBuckets": True,
}


@pytest.fixture
def reactive():
    s3, config = Mock(), Mock()
    s3.get_public_access_block.return_value = {"PublicAccessBlockConfiguration": ALL_BLOCKED}
    return load_handler(REACTIVE, s3=s3, config=config), s3, config


def reactive_event(message_type="ConfigurationItemChangeNotification", **item_overrides):
    item = {
        "resourceId": "bucket-a",
        "resourceType": "AWS::S3::Bucket",
        "configurationItemStatus": "OK",
        "configurationItemCaptureTime": "2026-10-08T00:00:00.000Z",
        "tags": {TAG_KEY: TAG_VALUE},
    }
    item.update(item_overrides)
    item_field = (
        "configurationItemSummary"
        if message_type == "OversizedConfigurationItemChangeNotification"
        else "configurationItem"
    )
    return {
        "resultToken": "token",
        "ruleParameters": RULE_PARAMETERS,
        "invokingEvent": json.dumps({"messageType": message_type, item_field: item}),
    }


def test_reactive_marks_all_public_access_block_settings_compliant(reactive):
    module, _, config = reactive

    assert module.lambda_handler(reactive_event(), None)["compliance"] == "COMPLIANT"
    assert put_evaluations(config)[0]["ComplianceType"] == "COMPLIANT"


def test_reactive_marks_partial_public_access_block_non_compliant(reactive):
    module, s3, _ = reactive
    s3.get_public_access_block.return_value = {
        "PublicAccessBlockConfiguration": {**ALL_BLOCKED, "BlockPublicPolicy": False}
    }

    assert module.lambda_handler(reactive_event(), None)["compliance"] == "NON_COMPLIANT"


def test_reactive_marks_missing_public_access_block_non_compliant(reactive):
    module, s3, _ = reactive
    s3.get_public_access_block.side_effect = client_error("NoSuchPublicAccessBlockConfiguration")

    assert module.lambda_handler(reactive_event(), None)["compliance"] == "NON_COMPLIANT"


def test_reactive_never_flags_buckets_without_scope_tag(reactive):
    module, s3, _ = reactive
    s3.get_public_access_block.side_effect = client_error("NoSuchPublicAccessBlockConfiguration")

    result = module.lambda_handler(reactive_event(tags={"Owner": "someone-else"}), None)

    assert result["compliance"] == "NOT_APPLICABLE"
    s3.get_public_access_block.assert_not_called()


@pytest.mark.parametrize("status", ["ResourceDeleted", "ResourceDeletedNotRecorded"])
def test_reactive_marks_deleted_bucket_not_applicable(reactive, status):
    module, s3, _ = reactive

    result = module.lambda_handler(reactive_event(configurationItemStatus=status), None)

    assert result["compliance"] == "NOT_APPLICABLE"
    s3.get_public_access_block.assert_not_called()


def test_reactive_marks_missing_bucket_not_applicable(reactive):
    module, s3, _ = reactive
    s3.get_public_access_block.side_effect = client_error("NoSuchBucket")

    assert module.lambda_handler(reactive_event(), None)["compliance"] == "NOT_APPLICABLE"


def test_reactive_marks_non_s3_resource_not_applicable(reactive):
    module, s3, _ = reactive

    result = module.lambda_handler(reactive_event(resourceType="AWS::EC2::Instance"), None)

    assert result["compliance"] == "NOT_APPLICABLE"
    s3.get_public_access_block.assert_not_called()


def test_reactive_reads_tags_from_s3_for_oversized_items(reactive):
    module, s3, _ = reactive
    s3.get_bucket_tagging.return_value = {"TagSet": [{"Key": TAG_KEY, "Value": TAG_VALUE}]}

    result = module.lambda_handler(
        reactive_event("OversizedConfigurationItemChangeNotification", tags=None), None
    )

    assert result["compliance"] == "COMPLIANT"
    s3.get_bucket_tagging.assert_called_once_with(Bucket="bucket-a")


def test_reactive_ignores_scheduled_notifications(reactive):
    module, _, config = reactive
    event = {
        "resultToken": "token",
        "ruleParameters": RULE_PARAMETERS,
        "invokingEvent": json.dumps({"messageType": "ScheduledNotification"}),
    }

    assert module.lambda_handler(event, None)["status"] == "ignored"
    config.put_evaluations.assert_not_called()
