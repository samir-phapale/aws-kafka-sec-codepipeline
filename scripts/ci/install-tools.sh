#!/usr/bin/env bash
# Installs pinned Terraform and/or conftest releases after verifying their
# SHA-256 checksums against the vendor's published checksum file.
#   install-tools.sh terraform conftest
# Versions come from TERRAFORM_VERSION / CONFTEST_VERSION (set on the
# CodeBuild projects by pipeline/).
set -euo pipefail

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

install_terraform() {
  local version="${TERRAFORM_VERSION:?TERRAFORM_VERSION is not set}"
  local archive="terraform_${version}_linux_amd64.zip"
  local base_url="https://releases.hashicorp.com/terraform/${version}"
  curl -fsSLO "${base_url}/${archive}"
  curl -fsSLO "${base_url}/terraform_${version}_SHA256SUMS"
  grep " ${archive}\$" "terraform_${version}_SHA256SUMS" | sha256sum -c -
  unzip -q -o "${archive}" terraform
  install -m 0755 terraform /usr/local/bin/terraform
  terraform version
}

install_conftest() {
  local version="${CONFTEST_VERSION:?CONFTEST_VERSION is not set}"
  local archive="conftest_${version}_Linux_x86_64.tar.gz"
  local base_url="https://github.com/open-policy-agent/conftest/releases/download/v${version}"
  curl -fsSLO "${base_url}/${archive}"
  curl -fsSLO "${base_url}/checksums.txt"
  grep " ${archive}\$" checksums.txt | sha256sum -c -
  tar -xzf "${archive}" conftest
  install -m 0755 conftest /usr/local/bin/conftest
  conftest --version
}

for tool in "$@"; do
  case "$tool" in
    terraform) install_terraform ;;
    conftest) install_conftest ;;
    *) echo "Unknown tool: $tool" >&2; exit 1 ;;
  esac
done
