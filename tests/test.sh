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
python3 -m py_compile \
  "${REPO_DIR}/scripts/build-dot-jay-bundle.py" \
  "${REPO_DIR}/scripts/render-cloud-init.py"

minimal_plan="$("${REPO_DIR}/jlx-cloud" --dry-run)"
assert_contains "${minimal_plan}" "provider=ubuntu"
assert_contains "${minimal_plan}" "profile=jlx-cloud"
assert_contains "${minimal_plan}" "dot-jay-source=bundle"
assert_contains "${minimal_plan}" "dot-jay-runtime-9a8ddcb6419d.tar.gz"
[[ "${minimal_plan}" != *"profile=jlx-cloud-host"* ]] || fail "Minimal mode selected the host profile"

host_plan="$("${REPO_DIR}/jlx-cloud" --host --dry-run)"
assert_contains "${host_plan}" "profile=jlx-cloud-host"

oci_plan="$("${REPO_DIR}/jlx-cloud" --provider oci --host --swap-gib 4 --dry-run)"
assert_contains "${oci_plan}" "provider=oci"
assert_contains "${oci_plan}" "profile=jlx-cloud-host"
assert_contains "${oci_plan}" "swap-gib=4"

version_output="$("${REPO_DIR}/jlx-cloud" --version)"
assert_contains "${version_output}" "jlx-cloud 0.2.0"

render_dir="$(mktemp -d)"
trap 'rm -rf "${render_dir}"' EXIT

minimal_render="${render_dir}/oci-minimal.yaml"
host_render="${render_dir}/oci-host.yaml"
custom_render="${render_dir}/ubuntu-custom.yaml"
"${REPO_DIR}/jlx-cloud" render --provider oci >"${minimal_render}"
"${REPO_DIR}/jlx-cloud" render --provider oci --host --swap-gib 4 >"${host_render}"
"${REPO_DIR}/jlx-cloud" render --provider ubuntu --user deploy >"${custom_render}"

grep -q '^#cloud-config$' "${minimal_render}" || fail "Rendered OCI config is missing its header"
grep -q -- '--provider, oci, --user, "ubuntu", --swap-gib, "2"' "${minimal_render}" || \
  fail "Rendered minimal OCI command is incorrect"
if grep -q -- '--host' "${minimal_render}"; then
  fail "Rendered minimal OCI config unexpectedly enables host mode"
fi
grep -q -- '--user, "ubuntu", --host, --swap-gib, "4"' "${host_render}" || \
  fail "Rendered OCI host command is incorrect"
grep -q -- '--provider, ubuntu, --user, "deploy"' "${custom_render}" || \
  fail "Rendered Ubuntu config did not apply the requested user"

if "${REPO_DIR}/jlx-cloud" --provider invalid --dry-run >/dev/null 2>&1; then
  fail "Invalid providers must fail"
fi
if "${REPO_DIR}/jlx-cloud" render --dry-run >/dev/null 2>&1; then
  fail "Render mode must reject --dry-run"
fi
if "${REPO_DIR}/jlx-cloud" render --dot-jay-ref main >/dev/null 2>&1; then
  fail "Render mode must reject dot-jay source overrides"
fi

git_plan="$("${REPO_DIR}/jlx-cloud" --dot-jay-ref main --dry-run)"
assert_contains "${git_plan}" "dot-jay-source=git"
if "${REPO_DIR}/jlx-cloud" --dot-jay-ref main \
  --dot-jay-bundle-url https://example.invalid/bundle.tar.gz --dry-run >/dev/null 2>&1; then
  fail "Git and bundle source overrides must be mutually exclusive"
fi

grep -q -- '--no-sync-private-keys' "${REPO_DIR}/scripts/bootstrap-ubuntu.sh" || \
  fail "dot-jay private-key sync must remain disabled"
grep -q 'sha256sum --check --status' "${REPO_DIR}/scripts/bootstrap-ubuntu.sh" || \
  fail "dot-jay bundles must remain checksum-verified"
grep -q 'DEFAULT_DOT_JAY_BUNDLE_SHA256="[0-9a-f]\{64\}"' \
  "${REPO_DIR}/config/defaults.env" || fail "The released dot-jay bundle checksum is invalid"
grep -q '00-jlx-cloud.conf' "${REPO_DIR}/scripts/bootstrap-ubuntu.sh" || \
  fail "The early OpenSSH hardening drop-in is missing"
grep -q -- '--firewall external' "${REPO_DIR}/scripts/bootstrap-oci.sh" || \
  fail "OCI must keep the provider firewall authoritative"

for config in "${REPO_DIR}"/cloud-init/*.yaml; do
  grep -q '^#cloud-config$' "${config}" || fail "${config} is missing the cloud-config header"
  grep -q 'v0.2.0' "${config}" || fail "${config} does not pin the jlx-cloud release"
  grep -q '^  - curl$' "${config}" || fail "${config} does not install the bundle downloader"
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
  cloud-init schema -c "${minimal_render}"
  cloud-init schema -c "${host_render}"
  cloud-init schema -c "${custom_render}"
elif [[ "${REQUIRE_CLOUD_INIT:-0}" == "1" ]]; then
  fail "cloud-init is required but unavailable"
else
  printf '[test] cloud-init unavailable; schema validation skipped\n'
fi

printf '[test] all available checks passed\n'
