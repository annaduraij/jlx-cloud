#!/usr/bin/env bash
# Author: Jay Annadurai
# Project: jlx-cloud
# Date: 22 September 2026
# File: scripts/bootstrap-oci.sh
# Description: Extends the Ubuntu bootstrap with conservative OCI Ampere A1 checks and tuning.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# defaults.env is part of this repository's trusted interface.
# shellcheck disable=SC1091
source "${REPO_DIR}/config/defaults.env"

TARGET_USER="ubuntu"
DOT_JAY_PROFILE="jlx-cloud"
DOT_JAY_REPO="${DEFAULT_DOT_JAY_REPO}"
DOT_JAY_REF="${DEFAULT_DOT_JAY_REF}"
DOT_JAY_BUNDLE_URL="${DEFAULT_DOT_JAY_BUNDLE_URL}"
DOT_JAY_BUNDLE_SHA256="${DEFAULT_DOT_JAY_BUNDLE_SHA256}"
SWAP_GIB=2

usage() {
  cat <<'EOF'
Usage: bootstrap-oci.sh [options]

Internal OCI bootstrap used by the public jlx-cloud command.

Options:
  --user USER          OCI login user.
  --profile PROFILE    jlx-cloud or jlx-cloud-host.
  --dot-jay-repo URL   dot-jay Git repository.
  --dot-jay-ref REF    Pinned dot-jay commit or release ref.
  --dot-jay-bundle-url URL
                       Released dot-jay runtime bundle URL.
  --dot-jay-bundle-sha256 SHA256
                       Expected runtime bundle checksum.
  --swap-gib SIZE      Emergency swap-file size, 0 through 16 (default: 2).
  -h, --help           Show this help.
EOF
}

log() {
  printf '[jlx-cloud oci] %s\n' "$*"
}

fail() {
  printf '[jlx-cloud oci] ERROR: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --user)
      [[ $# -ge 2 ]] || fail "--user requires a value"
      TARGET_USER="$2"
      shift 2
      ;;
    --profile)
      [[ $# -ge 2 ]] || fail "--profile requires a value"
      DOT_JAY_PROFILE="$2"
      shift 2
      ;;
    --dot-jay-repo)
      [[ $# -ge 2 ]] || fail "--dot-jay-repo requires a value"
      DOT_JAY_REPO="$2"
      shift 2
      ;;
    --dot-jay-ref)
      [[ $# -ge 2 ]] || fail "--dot-jay-ref requires a value"
      DOT_JAY_REF="$2"
      shift 2
      ;;
    --dot-jay-bundle-url)
      [[ $# -ge 2 ]] || fail "--dot-jay-bundle-url requires a value"
      DOT_JAY_BUNDLE_URL="$2"
      shift 2
      ;;
    --dot-jay-bundle-sha256)
      [[ $# -ge 2 ]] || fail "--dot-jay-bundle-sha256 requires a value"
      DOT_JAY_BUNDLE_SHA256="$2"
      shift 2
      ;;
    --swap-gib)
      [[ $# -ge 2 ]] || fail "--swap-gib requires a value"
      SWAP_GIB="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || fail "Run this bootstrap as root"
[[ "${SWAP_GIB}" =~ ^([0-9]|1[0-6])$ ]] || \
  fail "--swap-gib must be an integer from 0 through 16"

# Oracle warns that UFW can disrupt its provider-managed iSCSI firewall rules.
"${SCRIPT_DIR}/bootstrap-ubuntu.sh" \
  --user "${TARGET_USER}" \
  --profile "${DOT_JAY_PROFILE}" \
  --dot-jay-repo "${DOT_JAY_REPO}" \
  --dot-jay-ref "${DOT_JAY_REF}" \
  --dot-jay-bundle-url "${DOT_JAY_BUNDLE_URL}" \
  --dot-jay-bundle-sha256 "${DOT_JAY_BUNDLE_SHA256}" \
  --firewall external

for command_name in awk fallocate mkswap nproc swapon sysctl; do
  command -v "${command_name}" >/dev/null || fail "${command_name} is required"
done

ARCH="$(uname -m)"
CPU_COUNT="$(nproc)"
MEMORY_MIB="$(awk '/^MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo)"
log "Detected OCI guest resources: arch=${ARCH}, CPUs=${CPU_COUNT}, memory=${MEMORY_MIB} MiB"
if [[ "${ARCH}" != "aarch64" || "${CPU_COUNT}" -ne 2 || "${MEMORY_MIB}" -lt 11000 ]]; then
  log "Warning: this preset targets VM.Standard.A1.Flex with 2 OCPUs and 12 GB RAM"
fi

if command -v snap >/dev/null && snap list oracle-cloud-agent >/dev/null 2>&1; then
  log "Oracle Cloud Agent is installed"
  snap services oracle-cloud-agent
else
  log "Warning: Oracle Cloud Agent was not found; verify the OCI platform image"
fi

if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  log "Warning: UFW is active; OCI recommends leaving it disabled on Ubuntu platform images"
fi

if [[ "${SWAP_GIB}" -gt 0 ]] && ! swapon --show=NAME --noheadings | grep -q '[^[:space:]]'; then
  log "Creating a ${SWAP_GIB} GiB emergency swap file"
  fallocate -l "${SWAP_GIB}G" /swapfile
  chmod 0600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
    printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
  fi
else
  log "Keeping the existing swap configuration"
fi

# Retain the swap safety net without encouraging normal block-volume swapping.
cat > /etc/sysctl.d/60-jlx-cloud-oci.conf <<'EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
chmod 0644 /etc/sysctl.d/60-jlx-cloud-oci.conf
sysctl -p /etc/sysctl.d/60-jlx-cloud-oci.conf

log "OCI bootstrap completed"
