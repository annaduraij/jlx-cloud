#!/usr/bin/env bash
# Author: Jay Annadurai
# Project: jlx-cloud
# Date: 22 September 2026
# File: scripts/bootstrap-ubuntu.sh
# Description: Hardens Ubuntu, checks out a pinned dot-jay revision, and configures the login user.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091 -- defaults.env is part of this repository's trusted interface.
source "${REPO_DIR}/config/defaults.env"

TARGET_USER="ubuntu"
DOT_JAY_PROFILE="jlx-cloud"
DOT_JAY_REPO="${DEFAULT_DOT_JAY_REPO}"
DOT_JAY_REF="${DEFAULT_DOT_JAY_REF}"
FIREWALL_MODE="ufw"
EXPECTED_UBUNTU_VERSION="26.04"
DOT_JAY_DIR="/opt/dot-jay"

usage() {
  cat <<'EOF'
Usage: bootstrap-ubuntu.sh [options]

Internal Ubuntu bootstrap used by the public jlx-cloud command.

Options:
  --user USER              Login user that owns the dot-jay configuration.
  --profile PROFILE        jlx-cloud or jlx-cloud-host.
  --dot-jay-repo URL       dot-jay Git repository.
  --dot-jay-ref REF        Pinned dot-jay commit or release ref.
  --firewall MODE          ufw or external (default: ufw).
  --ubuntu-version VERSION Required Ubuntu version (default: 26.04).
  -h, --help               Show this help.
EOF
}

log() {
  printf '[jlx-cloud ubuntu] %s\n' "$*"
}

fail() {
  printf '[jlx-cloud ubuntu] ERROR: %s\n' "$*" >&2
  exit 1
}

run_as_target() {
  sudo -n -H -u "${TARGET_USER}" -- env HOME="${TARGET_HOME}" "$@"
}

assert_sshd_setting() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(sshd -T | awk -v key="${key}" '$1 == key {print $2; exit}')"
  [[ "${actual}" == "${expected}" ]] || \
    fail "Effective sshd setting ${key} is '${actual:-missing}', expected '${expected}'"
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
    --firewall)
      [[ $# -ge 2 ]] || fail "--firewall requires a value"
      FIREWALL_MODE="$2"
      shift 2
      ;;
    --ubuntu-version)
      [[ $# -ge 2 ]] || fail "--ubuntu-version requires a value"
      EXPECTED_UBUNTU_VERSION="$2"
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
[[ "${DOT_JAY_PROFILE}" == "jlx-cloud" || "${DOT_JAY_PROFILE}" == "jlx-cloud-host" ]] || \
  fail "--profile must be 'jlx-cloud' or 'jlx-cloud-host'"
[[ "${FIREWALL_MODE}" == "ufw" || "${FIREWALL_MODE}" == "external" ]] || \
  fail "--firewall must be 'ufw' or 'external'"
[[ -n "${DOT_JAY_REPO}" && -n "${DOT_JAY_REF}" ]] || \
  fail "The dot-jay repository and ref must not be blank"

# shellcheck disable=SC1091 -- /etc/os-release is the standard local OS identity file.
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || fail "This bootstrap supports Ubuntu only; detected '${ID:-unknown}'"
[[ "${VERSION_ID:-}" == "${EXPECTED_UBUNTU_VERSION}" ]] || \
  fail "Expected Ubuntu ${EXPECTED_UBUNTU_VERSION}; detected '${VERSION_ID:-unknown}'"

for command_name in apt-get getent git python3 sshd sudo systemctl usermod; do
  command -v "${command_name}" >/dev/null || fail "${command_name} is required"
done
id "${TARGET_USER}" >/dev/null 2>&1 || fail "Login user '${TARGET_USER}' does not exist"

TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "${TARGET_USER}")"
[[ -n "${TARGET_HOME}" && -d "${TARGET_HOME}" ]] || \
  fail "Cannot resolve a home directory for '${TARGET_USER}'"
[[ -s "${TARGET_HOME}/.ssh/authorized_keys" ]] || \
  fail "${TARGET_HOME}/.ssh/authorized_keys is empty; refusing to harden SSH"

export DEBIAN_FRONTEND=noninteractive
log "Installing Ubuntu security prerequisites"
apt-get update
apt-get install -y unattended-upgrades
if [[ "${FIREWALL_MODE}" == "ufw" ]]; then
  apt-get install -y ufw
fi

# Enable daily security updates without opting into unattended release upgrades.
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
chmod 0644 /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable --now unattended-upgrades.service

# OpenSSH uses the first value it reads, so this drop-in sorts before vendor files.
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-jlx-cloud.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
X11Forwarding no
EOF
chmod 0644 /etc/ssh/sshd_config.d/00-jlx-cloud.conf
sshd -t
assert_sshd_setting passwordauthentication no
assert_sshd_setting kbdinteractiveauthentication no
assert_sshd_setting permitrootlogin no
assert_sshd_setting pubkeyauthentication yes
assert_sshd_setting x11forwarding no
systemctl reload ssh.service

if [[ "${FIREWALL_MODE}" == "ufw" ]]; then
  log "Enabling the host firewall with SSH allowed"
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp comment 'SSH'
  ufw --force enable
else
  log "Leaving the host firewall unchanged; the cloud firewall is authoritative"
fi

# dot-jay performs package-manager operations through the target user's sudo policy.
run_as_target sudo -n true || \
  fail "${TARGET_USER} needs non-interactive sudo for the dot-jay package stage"

if [[ -e "${DOT_JAY_DIR}" && ! -d "${DOT_JAY_DIR}/.git" ]]; then
  fail "${DOT_JAY_DIR} exists but is not a Git checkout"
fi

if [[ ! -d "${DOT_JAY_DIR}/.git" ]]; then
  log "Cloning dot-jay into ${DOT_JAY_DIR}"
  install -d -o "${TARGET_USER}" -g "${TARGET_GROUP}" "${DOT_JAY_DIR}"
  run_as_target git clone --no-checkout "${DOT_JAY_REPO}" "${DOT_JAY_DIR}"
else
  origin_url="$(run_as_target git -C "${DOT_JAY_DIR}" remote get-url origin)"
  [[ "${origin_url}" == "${DOT_JAY_REPO}" ]] || \
    fail "Existing dot-jay checkout uses unexpected origin '${origin_url}'"
  run_as_target git -C "${DOT_JAY_DIR}" diff --quiet || \
    fail "Existing dot-jay checkout has unstaged tracked changes"
  run_as_target git -C "${DOT_JAY_DIR}" diff --cached --quiet || \
    fail "Existing dot-jay checkout has staged changes"
fi

log "Resolving pinned dot-jay ref ${DOT_JAY_REF}"
run_as_target git -C "${DOT_JAY_DIR}" fetch --depth 1 origin "${DOT_JAY_REF}"
resolved_ref="$(run_as_target git -C "${DOT_JAY_DIR}" rev-parse FETCH_HEAD)"
if [[ "${DOT_JAY_REF}" =~ ^[0-9a-fA-F]{40}$ ]]; then
  normalized_ref="$(printf '%s' "${DOT_JAY_REF}" | tr '[:upper:]' '[:lower:]')"
  [[ "${resolved_ref}" == "${normalized_ref}" ]] || \
    fail "Fetched dot-jay commit ${resolved_ref}, expected ${normalized_ref}"
fi
run_as_target git -C "${DOT_JAY_DIR}" checkout --detach "${resolved_ref}"
[[ -f "${DOT_JAY_DIR}/main.py" ]] || fail "dot-jay main.py was not found"

log "Running dot-jay profile '${DOT_JAY_PROFILE}' as '${TARGET_USER}'"
run_as_target python3 "${DOT_JAY_DIR}/main.py" sync \
  --profile "${DOT_JAY_PROFILE}" \
  --auto \
  --no-sync-private-keys

ZSH_PATH="$(command -v zsh)"
[[ -n "${ZSH_PATH}" ]] || fail "dot-jay completed without installing zsh"
usermod --shell "${ZSH_PATH}" "${TARGET_USER}"

if [[ -f /var/run/reboot-required ]]; then
  log "A package update requires a reboot; schedule it after verifying SSH access"
fi

log "Ubuntu bootstrap completed at dot-jay commit ${resolved_ref}"
