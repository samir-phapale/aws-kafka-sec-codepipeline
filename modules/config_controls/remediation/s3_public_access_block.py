"""Reactive remediation steps for S3 Public Access Block.

Embedded into the custom SSM Automation document (one aws:executeScript step
per handler). Each handler receives the step's InputPayload as `events` and
runs under the document's AutomationAssumeRole.
"""

import time

import boto3
from botocore.exceptions import ClientError

s3 = None

REQUIRED_SETTINGS = (
    "BlockPublicAcls",
    "IgnorePublicAcls",
    "BlockPublicPolicy",
    "RestrictPublicBuckets",
)
VERIFY_ATTEMPTS = 6
VERIFY_DELAY_SECONDS = 5


def get_client():
    global s3
    if s3 is None:
        s3 = boto3.client("s3")
    return s3


def current_settings(bucket):
    try:
        config = get_client().get_public_access_block(Bucket=bucket)
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "NoSuchPublicAccessBlockConfiguration":
            return {setting: False for setting in REQUIRED_SETTINGS}
        raise
    pab = config["PublicAccessBlockConfiguration"]
    return {setting: pab.get(setting) is True for setting in REQUIRED_SETTINGS}


def verify_scope_tag(events, context):
    """Refuse to modify a bucket that does not carry the scope tag.

    The Config rule scope and the rule Lambda already filter on this tag;
    this is the last check before anything is changed.
    """
    bucket = events["BucketName"]
    tag_key, tag_value = events["ScopeTagKey"], events["ScopeTagValue"]

    try:
        tag_set = get_client().get_bucket_tagging(Bucket=bucket)["TagSet"]
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "NoSuchTagSet":
            raise
        tag_set = []

    tags = {tag["Key"]: tag["Value"] for tag in tag_set}
    if tags.get(tag_key) != tag_value:
        raise ValueError(f"Refusing to remediate {bucket}: it does not carry {tag_key}={tag_value}")
    return {"Bucket": bucket, "ScopeTag": f"{tag_key}={tag_value}"}


def enable_public_access_block(events, context):
    """Turn on all four Public Access Block settings, recording the prior state."""
    bucket = events["BucketName"]
    before = current_settings(bucket)
    get_client().put_public_access_block(
        Bucket=bucket,
        PublicAccessBlockConfiguration={setting: True for setting in REQUIRED_SETTINGS},
    )
    return {"Bucket": bucket, "Before": before}


def verify_public_access_block(events, context):
    """Confirm all four settings are on; S3 can take a few seconds to reflect the change."""
    bucket = events["BucketName"]
    settings = {}
    for attempt in range(VERIFY_ATTEMPTS):
        settings = current_settings(bucket)
        if all(settings.values()):
            return {"Bucket": bucket, "After": settings}
        if attempt < VERIFY_ATTEMPTS - 1:
            time.sleep(VERIFY_DELAY_SECONDS)
    raise RuntimeError(f"Public Access Block on {bucket} still not fully enabled: {settings}")
