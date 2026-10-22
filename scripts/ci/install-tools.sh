#!/usr/bin/env bash
# Installs pinned Terraform and/or conftest after checking their SHA-256.
# Usage: install-tools.sh terraform conftest
set -euo pipefail

cd "$(mktemp -d)"

for tool in "$@"; do
  case "$tool" in
    terraform)
      archive="terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
      base_url="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}"
      curl -fsSLO "$base_url/$archive"
      curl -fsSLO "$base_url/terraform_${TERRAFORM_VERSION}_SHA256SUMS"
      grep " $archive\$" "terraform_${TERRAFORM_VERSION}_SHA256SUMS" | sha256sum -c -
      unzip -q "$archive" terraform
      ;;
    conftest)
      archive="conftest_${CONFTEST_VERSION}_Linux_x86_64.tar.gz"
      base_url="https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}"
      curl -fsSLO "$base_url/$archive"
      curl -fsSLO "$base_url/checksums.txt"
      grep " $archive\$" checksums.txt | sha256sum -c -
      tar -xzf "$archive" conftest
      ;;
    *)
      echo "Unknown tool: $tool" >&2
      exit 1
      ;;
  esac
  install -m 0755 "$tool" /usr/local/bin/
done
