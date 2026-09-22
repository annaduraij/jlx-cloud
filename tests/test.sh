#!/usr/bin/env bash
# Author: Jay Annadurai
# Project: jlx-cloud
# Date: 22 September 2026
# File: tests/test.sh
# Description: Validates the CLI contract, shell syntax, static security invariants, and cloud-init schemas.

set -Eeuo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf '[test] ERROR: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local text="$1"
  local expected="$2"
  [[ "${text}" == *"${expected}"* ]] || fail "Expected output to contain: ${expected}"
}

bash -n \
  "${REPO_DIR}/jlx-cloud" \
  "${REPO_DIR}/scripts/bootstrap-ubuntu.sh" \
  "${REPO_DIR}/scripts/bootstrap-oci.sh"

minimal_plan="$("${REPO_DIR}/jlx-cloud" --dry-run)"
assert_contains "${minimal_plan}" "provider=ubuntu"
assert_contains "${minimal_plan}" "profile=jlx-cloud"
[[ "${minimal_plan}" != *"profile=jlx-cloud-host"* ]] || fail "Minimal mode selected the host profile"

host_plan="$("${REPO_DIR}/jlx-cloud" --host --dry-run)"
assert_contains "${host_plan}" "profile=jlx-cloud-host"

oci_plan="$("${REPO_DIR}/jlx-cloud" --provider oci --host --swap-gib 4 --dry-run)"
assert_contains "${oci_plan}" "provider=oci"
assert_contains "${oci_plan}" "profile=jlx-cloud-host"
assert_contains "${oci_plan}" "swap-gib=4"

version_output="$("${REPO_DIR}/jlx-cloud" --version)"
assert_contains "${version_output}" "jlx-cloud 0.1.2"

if "${REPO_DIR}/jlx-cloud" --provider invalid --dry-run >/dev/null 2>&1; then
  fail "Invalid providers must fail"
fi

grep -q -- '--no-sync-private-keys' "${REPO_DIR}/scripts/bootstrap-ubuntu.sh" || \
  fail "dot-jay private-key sync must remain disabled"
grep -q '00-jlx-cloud.conf' "${REPO_DIR}/scripts/bootstrap-ubuntu.sh" || \
  fail "The early OpenSSH hardening drop-in is missing"
grep -q -- '--firewall external' "${REPO_DIR}/scripts/bootstrap-oci.sh" || \
  fail "OCI must keep the provider firewall authoritative"

for config in "${REPO_DIR}"/cloud-init/*.yaml; do
  grep -q '^#cloud-config$' "${config}" || fail "${config} is missing the cloud-config header"
  grep -q 'v0.1.2' "${config}" || fail "${config} does not pin the jlx-cloud release"
  if grep -q 'github_pat_' "${config}"; then
    fail "${config} contains a PAT-shaped value"
  fi
done

if command -v shellcheck >/dev/null; then
  shellcheck "${REPO_DIR}/jlx-cloud" "${REPO_DIR}"/scripts/*.sh "${REPO_DIR}/tests/test.sh"
elif [[ "${REQUIRE_SHELLCHECK:-0}" == "1" ]]; then
  fail "shellcheck is required but unavailable"
else
  printf '[test] shellcheck unavailable; skipped\n'
fi

if command -v cloud-init >/dev/null; then
  for config in "${REPO_DIR}"/cloud-init/*.yaml; do
    cloud-init schema -c "${config}"
  done
elif [[ "${REQUIRE_CLOUD_INIT:-0}" == "1" ]]; then
  fail "cloud-init is required but unavailable"
else
  printf '[test] cloud-init unavailable; schema validation skipped\n'
fi

printf '[test] all available checks passed\n'
