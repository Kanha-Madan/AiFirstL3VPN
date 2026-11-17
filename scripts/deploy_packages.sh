#!/usr/bin/env bash
# CD: copy the combined package bundle to the target NSO runtime and extract
# it directly into NSO_TARGET_PACKAGES_DIR (e.g. /var/opt/ncs/packages/).
# Usage: deploy_packages.sh <dev|stage|prod>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

ENV_NAME="${1:?usage: $0 <dev|stage|prod>}"
ARTIFACT_DIR="${ARTIFACT_DIR:-.artifacts}"
GIT_REF="${GIT_REF:-${BRANCH_NAME:-${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}}}"

case "${ENV_NAME}" in
  dev)
    : # any branch allowed
    ;;
  stage)
    [[ "${GIT_REF}" == release/* ]] || { echo "deploy ${ENV_NAME}: requires release/* branch (got ${GIT_REF})"; exit 1; }
    ;;
  prod)
    [[ "${GIT_REF}" == v* ]] || { echo "deploy ${ENV_NAME}: requires signed tag v* (got ${GIT_REF})"; exit 1; }
    ;;
  *)
    echo "deploy: unknown env '${ENV_NAME}'"; exit 2 ;;
esac

NSO_TARGET_HOST="${NSO_TARGET_HOST:?NSO_TARGET_HOST must be set (user@host)}"
NSO_TARGET_PACKAGES_DIR="${NSO_TARGET_PACKAGES_DIR:-/opt/ncs/packages}"

# SSH_PASSWORD (Username with password credential) or SSH_KEY_FILE (SSH
# private key credential) is populated by whichever withCredentials binding
# the Jenkinsfile uses for nso-deploy-ssh — setup_ssh_password_auth (in
# lib.sh) defines ssh_pw/scp_pw to authenticate with SSH_PASSWORD via sshpass
# or SSH_ASKPASS when present, and to fall back to plain ssh/scp otherwise
# (e.g. for SSH_KEY_FILE-based auth via -i below). No SSH Agent plugin is
# installed on this controller, so we can't rely on an ssh-agent socket
# either way. StrictHostKeyChecking=accept-new avoids disabling host-key
# verification outright while still tolerating first contact. BatchMode=yes
# is only safe to add for key-based auth — OpenSSH's BatchMode disables
# password/interactive prompting outright, which would break the
# SSH_ASKPASS/sshpass password path below.
SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
if [[ -n "${SSH_KEY_FILE:-}" ]]; then
  SSH_OPTS+=(-o BatchMode=yes -i "${SSH_KEY_FILE}")
fi
setup_ssh_password_auth

mkdir -p reports

shopt -s nullglob
artifacts=( "${ARTIFACT_DIR}"/nso-packages-*.tar.gz )
if [[ ${#artifacts[@]} -ne 1 ]]; then
  echo "deploy[${ENV_NAME}]: expected exactly one combined bundle (nso-packages-*.tar.gz) in ${ARTIFACT_DIR}, found ${#artifacts[@]} — run publish_artifact.sh first" >&2
  exit 1
fi
archive_path="${artifacts[0]}"
archive_name="$(basename "${archive_path}")"

echo "==> deploy[${ENV_NAME}]: computing local checksum for ${archive_name}"
if command -v sha256sum >/dev/null 2>&1; then
  local_sha="$(sha256sum "${archive_path}" | awk '{print $1}')"
else
  local_sha="$(openssl dgst -sha256 "${archive_path}" | awk '{print $NF}')"
fi

echo "==> deploy[${ENV_NAME}]: verifying NSO is started on ${NSO_TARGET_HOST}"
# `ncs --status` on a runtime with many packages dumps its ENTIRE state (every
# loaded YANG module, package, live session, CDB client, service/action
# point...) — hundreds of lines that are irrelevant here and just add noise to
# the Jenkins/Actions console. Keep the full dump in the log file for
# debugging, but only echo the one line we actually care about.
#
# NOTE: capture stderr too (2>&1, not 2>/dev/null) and check ssh_pw's own
# exit code explicitly rather than masking it with `|| true`. If the ssh
# connection itself fails (auth hiccup, host-key change, network blip,
# transient reset, etc.) the old `2>/dev/null || true` produced a silently
# empty $status with NO error recorded anywhere — indistinguishable from "NSO
# not started" but actually a connectivity/auth failure. Surfacing ssh_rc and
# stderr in the log makes that failure mode diagnosable instead of silent.
#
# NOTE: retry a few times before giving up. In practice this ssh call fails
# intermittently (same target, same NSO state, no consistent trigger) — a
# transient connection/auth blip, not a real "NSO down" condition. Retrying
# rides out the blip instead of failing the whole deploy on a one-off hiccup;
# the loop still surfaces the real ssh error/exit code if every attempt fails.
ssh_rc=0
for attempt in 1 2 3; do
  set +e
  status="$(ssh_pw "${SSH_OPTS[@]}" "${NSO_TARGET_HOST}" "ncs --status" 2>&1)"
  ssh_rc=$?
  set -e
  [[ ${ssh_rc} -eq 0 ]] && break
  echo "==> deploy[${ENV_NAME}]: ssh status check attempt ${attempt}/3 failed (exit ${ssh_rc}), retrying..." >&2
  sleep 3
done
echo "${status}" > reports/pre-deploy-status.log
if [[ ${ssh_rc} -ne 0 ]]; then
  echo "deploy[${ENV_NAME}]: ssh to ${NSO_TARGET_HOST} failed (exit ${ssh_rc}) after 3 attempts while checking NSO status — see reports/pre-deploy-status.log for the ssh/ncs error output" >&2
  exit 1
fi
# NOTE: use here-strings (<<<) rather than `echo ... | grep ...` here. With
# `set -o pipefail`, a `grep -m1`/`grep -q` that matches early on a large,
# multi-hundred-line `ncs --status` dump closes its end of the pipe and can
# SIGPIPE the still-writing `echo` before it finishes flushing. Bash's
# pipefail then reports that SIGPIPE (exit 141) as the pipeline's status even
# though grep itself matched successfully — causing this check to fail
# intermittently despite the status genuinely being "started". A here-string
# feeds grep from a temp file instead of a live pipe, so there's no writer
# process left to race/SIGPIPE.
grep -m1 '^status:' <<< "${status}" || echo "(no 'status:' line returned — see reports/pre-deploy-status.log)"
grep -q 'started' <<< "${status}" || {
  echo "deploy[${ENV_NAME}]: NSO is not in 'started' state on ${NSO_TARGET_HOST} — full output in reports/pre-deploy-status.log" >&2
  exit 1
}

# Snapshot CDB for rollback
echo "==> deploy[${ENV_NAME}]: snapshotting CDB on ${NSO_TARGET_HOST}"
ssh_pw "${SSH_OPTS[@]}" "${NSO_TARGET_HOST}" "ncs-backup" | tee reports/deploy-backup.log

remote_tmp="/tmp/${archive_name}"
echo "==> deploy[${ENV_NAME}]: copying ${archive_name} to ${NSO_TARGET_HOST}:${remote_tmp}"
scp_pw "${SSH_OPTS[@]}" "${archive_path}" "${NSO_TARGET_HOST}:${remote_tmp}"

echo "==> deploy[${ENV_NAME}]: verifying remote checksum matches local"
remote_sha="$(ssh_pw "${SSH_OPTS[@]}" "${NSO_TARGET_HOST}" "sha256sum '${remote_tmp}' 2>/dev/null | awk '{print \$1}' || openssl dgst -sha256 '${remote_tmp}' | awk '{print \$NF}'")"
if [[ "${remote_sha}" != "${local_sha}" ]]; then
  echo "deploy[${ENV_NAME}]: checksum mismatch after copy (local=${local_sha} remote=${remote_sha}) — aborting" >&2
  ssh_pw "${SSH_OPTS[@]}" "${NSO_TARGET_HOST}" "rm -f '${remote_tmp}'" || true
  exit 1
fi

# `tar -xzf` only overlays: it overwrites files present in the new archive
# but does NOT delete pre-existing files/packages that aren't in it. Left
# alone, a file removed from a package (or a package renamed/dropped from
# this bundle) would silently linger on the target forever. So we rm -rf
# each top-level package directory THIS bundle contains, immediately before
# extracting — giving a true clean replace for exactly what we're deploying,
# while leaving any package outside this bundle (NEDs, packages owned by
# another pipeline, etc.) untouched.
mapfile -t bundle_pkg_names < <(tar -tzf "${archive_path}" | awk -F/ '{print $1}' | sort -u)
echo "==> deploy[${ENV_NAME}]: clean-replacing ${#bundle_pkg_names[@]} package dir(s) in ${NSO_TARGET_PACKAGES_DIR}, then extracting"
printf '     - %s\n' "${bundle_pkg_names[@]}"

ssh_pw "${SSH_OPTS[@]}" "${NSO_TARGET_HOST}" bash -s -- "${NSO_TARGET_PACKAGES_DIR}" "${remote_tmp}" "${bundle_pkg_names[@]}" <<'REMOTE_SCRIPT'
set -euo pipefail
target_dir="$1"
archive="$2"
shift 2
mkdir -p "${target_dir}"
for pkg in "$@"; do
  rm -rf "${target_dir%/}/${pkg}"
done
tar -xzf "${archive}" -C "${target_dir}"
rm -f "${archive}"
REMOTE_SCRIPT
echo "==> deploy[${ENV_NAME}]: done — bundle extracted to ${NSO_TARGET_HOST}:${NSO_TARGET_PACKAGES_DIR}"
