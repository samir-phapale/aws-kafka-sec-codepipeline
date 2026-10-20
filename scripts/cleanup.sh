#!/usr/bin/env bash
set -euo pipefail

for bucket in "${PHASE3_VERSIONING_BUCKET:-}" "${PHASE3_REACTIVE_BUCKET:-}"; do
  if [[ -n "$bucket" ]]; then
    aws s3api delete-bucket --bucket "$bucket" --region "${AWS_REGION:-us-east-1}" || true
  fi
done

echo "Cleanup attempted. Empty any non-empty test bucket before deleting it."
