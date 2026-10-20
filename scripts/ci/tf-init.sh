#!/usr/bin/env bash
# terraform init against the remote S3 state of the Kafka stack.
# TF_STATE_BUCKET / TF_STATE_KEY are set on the CodeBuild projects;
# AWS_REGION is set by CodeBuild itself.
set -euo pipefail

terraform init -input=false -no-color \
  -backend-config="bucket=${TF_STATE_BUCKET:?TF_STATE_BUCKET is not set}" \
  -backend-config="key=${TF_STATE_KEY:?TF_STATE_KEY is not set}" \
  -backend-config="region=${AWS_REGION:?AWS_REGION is not set}" \
  -backend-config="use_lockfile=true" \
  -backend-config="encrypt=true"
