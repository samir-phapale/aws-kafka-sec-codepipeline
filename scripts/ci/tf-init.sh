#!/usr/bin/env bash
set -euo pipefail

terraform init -input=false -no-color \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${TF_STATE_KEY}" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="use_lockfile=true" \
  -backend-config="encrypt=true"
