import importlib.util
from pathlib import Path
from unittest.mock import Mock

import pytest
from botocore.exceptions import ClientError

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "modules/config_controls/remediation/s3_public_access_block.py"

TAG_KEY, TAG_VALUE = "Phase3Scope", "kafka-on-ec2-dev"
ALL_ON = {
    "BlockPublicAcls": True,
    "IgnorePublicAcls": True,
    "BlockPublicPolicy": True,
    "RestrictPublicBuckets": True,
}
ALL_OFF = {setting: False for setting in ALL_ON}


def client_error(code: str):
    return ClientError({"Error": {"Code": code, "Message": code}}, "Op")


@pytest.fixture
def remediation(monkeypatch):
    spec = importlib.util.spec_from_file_location(SCRIPT.stem, SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.s3 = Mock()
    monkeypatch.setattr(module.time, "sleep", lambda seconds: None)
    return module, module.s3


def scope_event(bucket="bucket-a"):
    return {"BucketName": bucket, "ScopeTagKey": TAG_KEY, "ScopeTagValue": TAG_VALUE}


# ---------------------------------------------------------------------------
# VerifyScopeTag
# ---------------------------------------------------------------------------


def test_verify_scope_tag_accepts_tagged_bucket(remediation):
    module, s3 = remediation
    s3.get_bucket_tagging.return_value = {"TagSet": [{"Key": TAG_KEY, "Value": TAG_VALUE}]}

    assert module.verify_scope_tag(scope_event(), None)["ScopeTag"] == f"{TAG_KEY}={TAG_VALUE}"


@pytest.mark.parametrize(
    "tag_set",
    [
        [],
        [{"Key": "Owner", "Value": "someone-else"}],
        [{"Key": TAG_KEY, "Value": "another-project"}],
    ],
)
def test_verify_scope_tag_refuses_untagged_or_foreign_bucket(remediation, tag_set):
    module, s3 = remediation
    s3.get_bucket_tagging.return_value = {"TagSet": tag_set}

    with pytest.raises(ValueError, match="Refusing to remediate"):
        module.verify_scope_tag(scope_event(), None)


def test_verify_scope_tag_refuses_bucket_without_any_tags(remediation):
    module, s3 = remediation
    s3.get_bucket_tagging.side_effect = client_error("NoSuchTagSet")

    with pytest.raises(ValueError, match="Refusing to remediate"):
        module.verify_scope_tag(scope_event(), None)


def test_verify_scope_tag_surfaces_unexpected_errors(remediation):
    module, s3 = remediation
    s3.get_bucket_tagging.side_effect = client_error("AccessDenied")

    with pytest.raises(ClientError):
        module.verify_scope_tag(scope_event(), None)


# ---------------------------------------------------------------------------
# EnablePublicAccessBlock
# ---------------------------------------------------------------------------


def test_enable_turns_on_all_four_settings_and_records_prior_state(remediation):
    module, s3 = remediation
    s3.get_public_access_block.return_value = {
        "PublicAccessBlockConfiguration": {**ALL_OFF, "BlockPublicAcls": True}
    }

    result = module.enable_public_access_block({"BucketName": "bucket-a"}, None)

    s3.put_public_access_block.assert_called_once_with(
        Bucket="bucket-a", PublicAccessBlockConfiguration=ALL_ON
    )
    assert result["Before"] == {**ALL_OFF, "BlockPublicAcls": True}


def test_enable_handles_bucket_with_no_configuration(remediation):
    module, s3 = remediation
    s3.get_public_access_block.side_effect = client_error("NoSuchPublicAccessBlockConfiguration")

    result = module.enable_public_access_block({"BucketName": "bucket-a"}, None)

    assert result["Before"] == ALL_OFF
    s3.put_public_access_block.assert_called_once()


# ---------------------------------------------------------------------------
# VerifyPublicAccessBlock
# ---------------------------------------------------------------------------


def test_verify_succeeds_when_all_settings_are_on(remediation):
    module, s3 = remediation
    s3.get_public_access_block.return_value = {"PublicAccessBlockConfiguration": ALL_ON}

    assert module.verify_public_access_block({"BucketName": "bucket-a"}, None)["After"] == ALL_ON


def test_verify_retries_until_settings_propagate(remediation):
    module, s3 = remediation
    s3.get_public_access_block.side_effect = [
        {"PublicAccessBlockConfiguration": ALL_OFF},
        {"PublicAccessBlockConfiguration": ALL_ON},
    ]

    assert module.verify_public_access_block({"BucketName": "bucket-a"}, None)["After"] == ALL_ON
    assert s3.get_public_access_block.call_count == 2


def test_verify_fails_when_settings_never_turn_on(remediation):
    module, s3 = remediation
    s3.get_public_access_block.return_value = {"PublicAccessBlockConfiguration": ALL_OFF}

    with pytest.raises(RuntimeError, match="still not fully enabled"):
        module.verify_public_access_block({"BucketName": "bucket-a"}, None)
    assert s3.get_public_access_block.call_count == module.VERIFY_ATTEMPTS
