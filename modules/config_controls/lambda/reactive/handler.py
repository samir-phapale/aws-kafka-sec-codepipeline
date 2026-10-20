import json
import logging
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

s3 = None
config = None

REQUIRED_SETTINGS = (
    "BlockPublicAcls",
    "BlockPublicPolicy",
    "IgnorePublicAcls",
    "RestrictPublicBuckets",
)
DELETED_STATUSES = ("ResourceDeleted", "ResourceDeletedNotRecorded")


def get_clients():
    global s3, config
    if s3 is None:
        s3 = boto3.client("s3")
    if config is None:
        config = boto3.client("config")


def rule_parameters(event):
    params = json.loads(event.get("ruleParameters") or "{}")
    tag_key, tag_value = params.get("TagKey"), params.get("TagValue")
    if not tag_key or not tag_value:
        raise ValueError("TagKey and TagValue rule parameters are required")
    return tag_key, tag_value


def bucket_tags(item: dict, bucket_name: str) -> dict:
    """Tags from the configuration item, or from S3 when Config omits them
    (oversized notifications only carry a summary without tags)."""
    if item.get("tags") is not None:
        return item["tags"]
    try:
        tag_set = s3.get_bucket_tagging(Bucket=bucket_name)["TagSet"]
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("NoSuchTagSet", "NoSuchBucket"):
            return {}
        raise
    return {tag["Key"]: tag["Value"] for tag in tag_set}


def evaluate(event: dict, item: dict, tag_key: str, tag_value: str):
    """Return (compliance, annotation) for one configuration item."""
    bucket_name = item.get("resourceId")

    if item.get("resourceType") != "AWS::S3::Bucket":
        return "NOT_APPLICABLE", "Rule only applies to S3 buckets."
    if event.get("eventLeftScope") or item.get("configurationItemStatus") in DELETED_STATUSES:
        return "NOT_APPLICABLE", "Bucket was deleted or left the rule scope."
    # Defense in depth on top of the rule's tag scope: never let a bucket we
    # do not own reach the automatic remediation.
    if bucket_tags(item, bucket_name).get(tag_key) != tag_value:
        return "NOT_APPLICABLE", f"Bucket does not carry {tag_key}={tag_value}."

    try:
        pab = s3.get_public_access_block(Bucket=bucket_name)["PublicAccessBlockConfiguration"]
    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        if code == "NoSuchBucket":
            return "NOT_APPLICABLE", "Bucket no longer exists."
        if code == "NoSuchPublicAccessBlockConfiguration":
            return "NON_COMPLIANT", "S3 Public Access Block configuration is missing."
        raise

    if all(pab.get(setting) is True for setting in REQUIRED_SETTINGS):
        return "COMPLIANT", "All S3 Public Access Block settings are enabled."
    return "NON_COMPLIANT", "All four S3 Public Access Block settings must be enabled."


def lambda_handler(event, context):
    """Change-triggered AWS Config custom rule (reactive).

    Detects whether all four S3 Public Access Block settings are enabled on
    buckets carrying the scope tag. Remediation is not done here: AWS Config's
    remediation configuration runs the custom SSM Automation document on
    NON_COMPLIANT results.
    """
    LOG.info("Received Config event: %s", json.dumps(event))
    get_clients()

    token = event.get("resultToken")
    if not token:
        raise ValueError("AWS Config resultToken is missing")

    invoking_event = json.loads(event.get("invokingEvent", "{}"))
    message_type = invoking_event.get("messageType")

    if message_type == "ConfigurationItemChangeNotification":
        item = invoking_event.get("configurationItem", {})
    elif message_type == "OversizedConfigurationItemChangeNotification":
        item = invoking_event.get("configurationItemSummary", {})
    else:
        return {"status": "ignored", "reason": f"unsupported message type {message_type}"}

    bucket_name = item.get("resourceId")
    if not bucket_name:
        raise ValueError("resourceId is missing from Config event")

    tag_key, tag_value = rule_parameters(event)
    compliance, annotation = evaluate(event, item, tag_key, tag_value)

    config.put_evaluations(
        Evaluations=[
            {
                "ComplianceResourceType": item.get("resourceType", "AWS::S3::Bucket"),
                "ComplianceResourceId": bucket_name,
                "ComplianceType": compliance,
                "OrderingTimestamp": item.get("configurationItemCaptureTime") or datetime.now(timezone.utc),
                "Annotation": annotation[:256],
            }
        ],
        ResultToken=token,
    )

    return {"bucket": bucket_name, "compliance": compliance}
