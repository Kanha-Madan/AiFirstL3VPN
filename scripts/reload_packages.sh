#!/usr/bin/env bash
# CD: trigger packages reload on the target NSO and verify oper-status.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

NSO_TARGET_HOST="${NSO_TARGET_HOST:?must be set}"

# SSH_PASSWORD or SSH_KEY_FILE is populated by whichever withCredentials
# binding the Jenkinsfile uses for nso-deploy-ssh — see deploy_packages.sh
# for the full explanation (no SSH Agent plugin on this controller, and
# nso-deploy-ssh is currently a "Username with password" credential).
NSO_ADMIN_USER="${NSO_ADMIN_USER:-admin}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
if [[ -n "${SSH_KEY_FILE:-}" ]]; then
  SSH_OPTS+=(-o BatchMode=yes -i "${SSH_KEY_FILE}")
fi
setup_ssh_password_auth

mkdir -p reports

echo "==> reload: packages reload force on ${NSO_TARGET_HOST}"
# -J accepts 'request …' verbs; pipe the command via stdin (see setup_packages.sh).
echo 'request packages reload force' \
  | ssh_pw "${SSH_OPTS[@]}" "${NSO_TARGET_HOST}" "ncs_cli -u ${NSO_ADMIN_USER} -J" \
  | tee reports/reload.log
echo 'show packages package oper-status' \
  | ssh_pw "${SSH_OPTS[@]}" "${NSO_TARGET_HOST}" "ncs_cli -u ${NSO_ADMIN_USER} -C" \
  | tee reports/reload-status.log

if grep -E 'oper-status (error|program-code-error|init)' reports/reload-status.log; then
  echo "==> reload: package not up — capturing logs and FAILING"
  ssh_pw "${SSH_OPTS[@]}" "${NSO_TARGET_HOST}" "tail -200 /var/log/ncs/ncserr.log; tail -200 /var/log/ncs/*-package.log" | tee reports/reload-error.log || true
  exit 1
fi
echo "==> reload: all packages up"
