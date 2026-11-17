#!/usr/bin/env bash

set -euo pipefail

# scripts/ lives at repo root, so one level up resolves project root.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/.artifacts}"

log_step() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

require_env() {
  local var_name="$1"
  if [[ -z "${!var_name:-}" ]]; then
    echo "Missing required environment variable: $var_name" >&2
    return 1
  fi
}

ensure_artifact_dir() {
  mkdir -p "$ARTIFACT_DIR"
}

write_placeholder_report() {
  local file_name="$1"
  local title="$2"

  ensure_artifact_dir

  cat > "$ARTIFACT_DIR/$file_name" <<EOF
$title
generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
repository_root=$ROOT_DIR
EOF
}

# ---------------------------------------------------------------------------
# Password-based SSH auth for CD scripts.
#
# The nso-deploy-ssh Jenkins credential is a "Username with password"
# credential (not an SSH private key, and the SSH Agent plugin isn't
# installed on this controller either), so ssh/scp need a way to
# authenticate non-interactively with just $SSH_PASSWORD. This defines
# ssh_pw()/scp_pw() wrapper functions — call setup_ssh_password_auth once,
# then use ssh_pw/scp_pw exactly like ssh/scp everywhere else.
#
# Preference order:
#   1. sshpass, if installed — simplest and most direct.
#   2. OpenSSH's own SSH_ASKPASS mechanism, forced via `setsid` (detaches
#      from the controlling tty so ssh/scp cannot prompt interactively and
#      must invoke SSH_ASKPASS instead). Works without any extra packages.
#   3. If SSH_PASSWORD isn't set at all (e.g. key-based auth configured via
#      -i elsewhere), ssh_pw/scp_pw just forward straight to ssh/scp.
# ---------------------------------------------------------------------------
_SSH_ASKPASS_TMP=""

_cleanup_ssh_askpass() {
  [[ -n "${_SSH_ASKPASS_TMP}" && -f "${_SSH_ASKPASS_TMP}" ]] && rm -f "${_SSH_ASKPASS_TMP}"
}

setup_ssh_password_auth() {
  if [[ -z "${SSH_PASSWORD:-}" ]]; then
    ssh_pw() { ssh "$@"; }
    scp_pw() { scp "$@"; }
    return 0
  fi

  if command -v sshpass >/dev/null 2>&1; then
    ssh_pw() { sshpass -p "${SSH_PASSWORD}" ssh "$@"; }
    scp_pw() { sshpass -p "${SSH_PASSWORD}" scp "$@"; }
    return 0
  fi

  if ! command -v setsid >/dev/null 2>&1; then
    echo "ERROR: neither 'sshpass' nor 'setsid' is available on this agent, so a" >&2
    echo "       password credential can't be used non-interactively. Install" >&2
    echo "       sshpass on the agent, or switch the nso-deploy-ssh Jenkins" >&2
    echo "       credential to an SSH private key (more secure) instead." >&2
    return 1
  fi

  # The askpass script below runs as a separate process (invoked by ssh/scp,
  # not sourced), so SSH_PASSWORD must actually be exported for it to see the
  # value at all — a plain shell variable would appear empty to it.
  export SSH_PASSWORD

  _SSH_ASKPASS_TMP="$(mktemp)"
  trap _cleanup_ssh_askpass EXIT
  cat > "${_SSH_ASKPASS_TMP}" <<'ASKPASS'
#!/usr/bin/env bash
printf '%s\n' "${SSH_PASSWORD}"
ASKPASS
  chmod 700 "${_SSH_ASKPASS_TMP}"
  export SSH_ASKPASS="${_SSH_ASKPASS_TMP}"
  export SSH_ASKPASS_REQUIRE=force

  # Deliberately NOT redirecting stdin to /dev/null here: setsid detaching
  # from the controlling tty is what forces ssh to use SSH_ASKPASS instead of
  # an interactive prompt, regardless of what stdin is connected to. Callers
  # (e.g. deploy_packages.sh's remote `bash -s --` script, or `echo cmd |
  # ssh_pw ...` in reload_packages.sh) rely on being able to pipe a real
  # stdin through to the remote command.
  ssh_pw() { setsid ssh "$@"; }
  scp_pw() { setsid scp "$@"; }
}
