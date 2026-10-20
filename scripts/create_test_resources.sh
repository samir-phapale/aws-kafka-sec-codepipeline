#!/usr/bin/env bash
# Creates two disposable S3 buckets that violate the Phase 3 controls.
# Both carry the compliance scope tag; untagged buckets are ignored by the
# rules by design. Run from the repo root after `terraform apply`.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
TAG_KEY="${PHASE3_SCOPE_TAG_KEY:-$(terraform output -raw compliance_scope_tag_key)}"
TAG_VALUE="${PHASE3_SCOPE_TAG_VALUE:-$(terraform output -raw compliance_scope_tag_value)}"
SUFFIX="$(aws sts get-caller-identity --query Account --output text)-$(date +%s)"
VERSIONING_BUCKET="phase3-versioning-${SUFFIX}"
REACTIVE_BUCKET="phase3-reactive-${SUFFIX}"

create_bucket() {
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$1" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$1" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  aws s3api put-bucket-tagging --bucket "$1" \
    --tagging "TagSet=[{Key=${TAG_KEY},Value=${TAG_VALUE}}]"
}

create_bucket "$VERSIONING_BUCKET"
create_bucket "$REACTIVE_BUCKET"

# The detective test intentionally leaves versioning disabled.
# The reactive test intentionally disables S3 Public Access Block.
aws s3api put-public-access-block \
  --bucket "$REACTIVE_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false

cat <<EOF
Created Phase 3 test buckets (tagged ${TAG_KEY}=${TAG_VALUE}):

Detective:
  $VERSIONING_BUCKET
  Versioning: disabled  -> expect NON_COMPLIANT on the next periodic run

Reactive:
  $REACTIVE_BUCKET
  Public Access Block: disabled  -> expect NON_COMPLIANT, then automatic remediation, then COMPLIANT

To trigger the periodic detective rule now instead of waiting:
  aws configservice describe-conformance-pack-compliance \\
    --conformance-pack-name "\$(terraform output -raw phase3_conformance_pack_name)"
  aws configservice start-config-rules-evaluation --config-rule-names <detective rule name from above>

Export these for scripts/cleanup.sh:
  export PHASE3_VERSIONING_BUCKET=$VERSIONING_BUCKET
  export PHASE3_REACTIVE_BUCKET=$REACTIVE_BUCKET
EOF
