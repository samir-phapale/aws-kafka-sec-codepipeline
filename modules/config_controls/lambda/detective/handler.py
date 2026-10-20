import json
import logging
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

s3 = None
config = None
tagging = None

# PutEvaluations accepts at most 100 evaluations per call.
MAX_EVALUATIONS_PER_CALL = 100


def get_clients():
    global s3, config, tagging
    if s3 is None:
        s3 = boto3.client("s3")
    if config is None:
        config = boto3.client("config")
    if tagging is None:
        tagging = boto3.client("resourcegroupstaggingapi")


def rule_parameters(event):
    params = json.loads(event.get("ruleParameters") or "{}")
    tag_key, tag_value = params.get("TagKey"), params.get("TagValue")
    if not tag_key or not tag_value:
        raise ValueError("TagKey and TagValue rule parameters are required")
    return tag_key, tag_value


def scoped_buckets(tag_key: str, tag_value: str):
    """Yield the names of buckets carrying the scope tag."""
    paginator = tagging.get_paginator("get_resources")
    pages = paginator.paginate(
        TagFilters=[{"Key": tag_key, "Values": [tag_value]}],
        ResourceTypeFilters=["s3"],
    )
    for page in pages:
        for mapping in page.get("ResourceTagMappingList", []):
            # Bucket ARNs look like arn:aws:s3:::bucket-name
            yield mapping["ResourceARN"].split(":::", 1)[1]


def bucket_region(bucket_name: str) -> str:
    location = s3.get_bucket_location(Bucket=bucket_name).get("LocationConstraint")
    # A null constraint means us-east-1; "EU" is the legacy name for eu-west-1.
    return {None: "us-east-1", "": "us-east-1", "EU": "eu-west-1"}.get(location, location)


def evaluation(bucket_name: str, compliance: str, annotation: str):
    return {
        "ComplianceResourceType": "AWS::S3::Bucket",
        "ComplianceResourceId": bucket_name,
        "ComplianceType": compliance,
        "OrderingTimestamp": datetime.now(timezone.utc),
        "Annotation": annotation[:256],
    }


def lambda_handler(event, context):
    """Periodic AWS Config custom rule (detective, report only).

    Only buckets that carry the scope tag and live in this Lambda's region
    are evaluated, which keeps the rule safe and fast in a shared account.
    A bucket is COMPLIANT when its versioning status is Enabled.
    """
    LOG.info("Received Config event: %s", json.dumps(event))
    get_clients()

    token = event.get("resultToken")
    if not token:
        raise ValueError("AWS Config resultToken is missing")

    tag_key, tag_value = rule_parameters(event)
    region = os.environ.get("AWS_REGION", "us-east-1")
    evaluations = []

    for name in scoped_buckets(tag_key, tag_value):
        try:
            if bucket_region(name) != region:
                continue
            status = s3.get_bucket_versioning(Bucket=name).get("Status")
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "NoSuchBucket":
                # The Tagging API is eventually consistent; skip deleted buckets.
                continue
            LOG.exception("Could not evaluate bucket %s", name)
            evaluations.append(
                evaluation(name, "NOT_APPLICABLE", f"Evaluation error: {exc.response['Error']['Code']}")
            )
            continue

        if status == "Enabled":
            evaluations.append(evaluation(name, "COMPLIANT", "S3 bucket versioning is enabled."))
        else:
            evaluations.append(evaluation(name, "NON_COMPLIANT", "S3 bucket versioning must be Enabled."))

    for start in range(0, len(evaluations), MAX_EVALUATIONS_PER_CALL):
        config.put_evaluations(
            Evaluations=evaluations[start : start + MAX_EVALUATIONS_PER_CALL],
            ResultToken=token,
        )

    return {"evaluated": len(evaluations)}
