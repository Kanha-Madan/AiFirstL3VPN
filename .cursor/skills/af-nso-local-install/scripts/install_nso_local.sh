#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  install_nso_local.sh /path/to/nso-<version>.*.installer.bin [options]  # use a local installer
  install_nso_local.sh <nso-version> [options]                           # fetch that version, then install
  install_nso_local.sh --fetch [options]                                 # fetch latest, then install

Options:
  --fetch                Resolve/download the NSO installer for this host via
                         the artifact manifest (dl.tail-f.com) before installing
  --runtime-dir <path>   NSO runtime directory (default: $HOME/nso-run-<version>)
  --install-dir <path>   NSO install directory (default: $HOME/nso-<version>)
  --persist-env          Add 'source <install>/ncsrc' (and the admin credential file,
                         when one exists) to shell profile files
  --start                Start NSO after runtime setup; also provisions the admin
                         password (see Credentials below)
  --insecure-default-admin
                         Allow finishing without provisioning the admin password
                         when NSO is not running (the known NSO default stays in
                         force; throwaway development setups only)
  --dev-mode             Enable development mode (license smart development enable)
  --explore              List examples, NEDs, and documentation after setup
  --verify               Verify installation by checking key directories
  --enable-restconf      Enable RESTCONF API in ncs.conf (requires --start to take effect)
  --restconf-port <p>    RESTCONF/WebUI port (default: 8080, requires --enable-restconf)
  -h, --help             Show this help

What this script does:
  1) Local install of NSO into your home directory (or --install-dir)
  2) Sources ncsrc from the local install
  3) Creates a runtime instance with ncs-setup --dest
  4) Optionally starts NSO and verifies status
  5) With NSO running, provisions the admin password (see Credentials)

Credentials:
  The admin password is never the NSO default. When NSO is running (--start or
  already up) the script uses $NSO_ADMIN_PASSWORD if set, else the value saved in
  <runtime>/nso-admin.env, else generates 24 random alphanumeric characters. It
  sets that password on the NSO admin user, saves NSO_ADMIN_USER and
  NSO_ADMIN_PASSWORD to <runtime>/nso-admin.env (mode 600), and never prints the
  value. Load it in your shell with:  source <runtime>/nso-admin.env
  Without a running NSO the script fails rather than leave the default password in
  force, unless --insecure-default-admin is given.

Notes:
  - Based on Cisco NSO Local Install guidance:
      sh <installer.bin> $HOME/nso-<version> --local-install
  - Input may be a local installer .bin, an NSO version (auto-downloaded), or
    --fetch (downloads the latest for this host). signed.bin is not accepted;
    fetched installers are already unpacked .installer.bin files.
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

err() {
  printf '[ERROR] %s\n' "$*" >&2
}

# Print file/line context on unexpected failures so users know exactly where things broke.
trap 'ec=$?; [[ $ec -ne 0 ]] && err "Script failed at line ${LINENO} (exit ${ec}). Check output above for details."' ERR

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "Required command not found: $cmd"
    exit 1
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH_NED="$SCRIPT_DIR/../../af-nso-install-ned/scripts/fetch_ned.sh"

# First positional argument (if not an option) is either a local .installer.bin
# path OR an NSO version to fetch. If absent, the latest installer is fetched.
INSTALLER_BIN=""
if [[ $# -ge 1 && "$1" != -* ]]; then
  INSTALLER_BIN="$1"
  shift
fi

FETCH_INSTALLER="false"
NSO_VERSION_REQ=""
START_NSO="false"
ALLOW_DEFAULT_ADMIN="false"
PERSIST_ENV="false"
DEV_MODE="false"
EXPLORE="false"
VERIFY="false"
ENABLE_RESTCONF="false"
RESTCONF_PORT="8080"
INSTALL_DIR=""
# NSO CLI admin identity used for dev-mode/reload commands — override via env.
NSO_ADMIN_USER="${NSO_ADMIN_USER:-admin}"
RUNTIME_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-dir)
      [[ $# -ge 2 ]] || { err "--runtime-dir needs a value"; exit 1; }
      RUNTIME_DIR="$2"
      shift 2
      ;;
    --install-dir)
      [[ $# -ge 2 ]] || { err "--install-dir needs a value"; exit 1; }
      INSTALL_DIR="$2"
      shift 2
      ;;
    --start)
      START_NSO="true"
      shift
      ;;
    --insecure-default-admin)
      ALLOW_DEFAULT_ADMIN="true"
      shift
      ;;
    --fetch)
      FETCH_INSTALLER="true"
      shift
      ;;
    --persist-env)
      PERSIST_ENV="true"
      shift
      ;;
    --dev-mode)
      DEV_MODE="true"
      shift
      ;;
    --explore)
      EXPLORE="true"
      shift
      ;;
    --verify)
      VERIFY="true"
      shift
      ;;
    --enable-restconf)
      ENABLE_RESTCONF="true"
      shift
      ;;
    --restconf-port)
      [[ $# -ge 2 ]] || { err "--restconf-port needs a value"; exit 1; }
      RESTCONF_PORT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Decide whether to resolve/download the installer from dl.tail-f.com.
#  - no positional arg            -> fetch latest
#  - positional that isn't a file -> treat as NSO version to fetch
#  - --fetch                      -> fetch (optionally with a version arg)
if [[ -z "$INSTALLER_BIN" ]]; then
  FETCH_INSTALLER="true"
elif [[ ! -f "$INSTALLER_BIN" && "$INSTALLER_BIN" != *.installer.bin ]]; then
  NSO_VERSION_REQ="$INSTALLER_BIN"
  FETCH_INSTALLER="true"
fi

if [[ "$FETCH_INSTALLER" == "true" ]]; then
  if [[ ! -x "$FETCH_NED" ]]; then
    err "Cannot fetch installer: $FETCH_NED not found or not executable"
    exit 1
  fi
  log "Resolving NSO installer via manifest (${NSO_VERSION_REQ:-latest}) ..."
  INSTALLER_BIN="$("$FETCH_NED" --nso-installer ${NSO_VERSION_REQ:+"$NSO_VERSION_REQ"} | tail -1)"
  if [[ -z "$INSTALLER_BIN" || ! -f "$INSTALLER_BIN" ]]; then
    err "Installer download failed."
    exit 1
  fi
  log "Using installer: $INSTALLER_BIN"
fi

if [[ ! -f "$INSTALLER_BIN" ]]; then
  err "Installer file does not exist: $INSTALLER_BIN"
  exit 1
fi

if [[ "$INSTALLER_BIN" != *.installer.bin ]]; then
  err "Expected an installer file ending with .installer.bin"
  err "Given: $INSTALLER_BIN"
  exit 1
fi

require_cmd sh
require_cmd sed

persist_shell_env() {
  local ncsrc_path="$1"
  local marker="# Added by install_nso_local.sh"
  local source_line="source \"$ncsrc_path\""
  # Optional files may be deleted later, so guard them to keep new shells quiet.
  if [[ "${2:-}" == "optional" ]]; then
    source_line="[ -f \"$ncsrc_path\" ] && source \"$ncsrc_path\""
  fi
  local profile

  for profile in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile"; do
    if [[ ! -f "$profile" ]]; then
      touch "$profile"
    fi

    if grep -Fq "$source_line" "$profile"; then
      log "Profile already configured: $profile"
      continue
    fi

    {
      printf '\n%s\n' "$marker"
      printf '%s\n' "$source_line"
    } >> "$profile"

    log "Updated profile: $profile"
  done
}

enable_restconf_in_conf() {
  local conf="$1"
  local port="$2"

  if [[ ! -f "$conf" ]]; then
    err "ncs.conf not found at: $conf"
    return 1
  fi

  if ! grep -q '<restconf>' "$conf"; then
    err "No <restconf> section found in $conf. Cannot patch automatically."
    return 1
  fi

  # Use Python for safe XML patching — avoids multiline sed portability issues.
  python3 - "$conf" "$port" <<'PYEOF'
import re, sys
conf, port = sys.argv[1], sys.argv[2]
content = open(conf).read()
# Enable <restconf><enabled>
content = re.sub(
    r'(<restconf>.*?<enabled>)false(</enabled>)',
    r'\1true\2', content, flags=re.DOTALL)
# Enable <webui><transport><tcp><enabled>
content = re.sub(
    r'(<webui>.*?<transport>.*?<tcp>.*?<enabled>)false(</enabled>)',
    r'\1true\2', content, flags=re.DOTALL)
# Set <webui><transport><tcp><port>
content = re.sub(
    r'(<webui>.*?<transport>.*?<tcp>.*?<port>)\d+(</port>)',
    lambda m: m.group(1) + port + m.group(2), content, flags=re.DOTALL)
open(conf, 'w').write(content)
print('[INFO] RESTCONF enabled in ' + conf + ' on port ' + port)
PYEOF
}

explore_installation() {
  local install_dir="$1"
  printf '\n'
  log "=== Exploring NSO Installation ==="

  if [[ -d "$install_dir/examples.ncs" ]]; then
    printf '\n'
    log "Available examples:"
    ls -1 "$install_dir/examples.ncs/" | sed 's/^/  /'
  fi

  if [[ -d "$install_dir/packages/neds" ]]; then
    printf '\n'
    log "Available NEDs (Network Element Drivers):"
    ls -1 "$install_dir/packages/neds/" | sed 's/^/  /'
  fi

  if [[ -f "$install_dir/doc/index.html" ]]; then
    printf '\n'
    log "Documentation available at: $install_dir/doc/index.html"
  fi
}

enable_dev_mode() {
  local runtime_dir="$1"
  log "Enabling development mode for NSO..."
  if ! command -v ncs_cli >/dev/null 2>&1; then
    err "ncs_cli not available. Ensure NSO environment is sourced."
    return 1
  fi
  ncs_cli -u "${NSO_ADMIN_USER}" -C 'license smart development enable' || {
    err "Failed to enable development mode. Ensure NSO is running or try manually:"
    err "  cd \"$runtime_dir\" && ncs_cli -u ${NSO_ADMIN_USER} -C 'license smart development enable'"
    return 1
  }
  log "Development mode enabled."
}

nso_running() {
  local runtime_dir="$1" pid_file="$1/logs/ncs.pid"
  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    return 0
  fi
  [[ -n "$(pgrep -f "conffile $runtime_dir/ncs.conf" 2>/dev/null | head -1 || true)" ]]
}

generate_password() {
  local pw
  # head closes the pipe early, so tolerate the SIGPIPE status under pipefail.
  pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
  if [[ ${#pw} -ne 24 ]]; then
    err "Could not generate an admin password from /dev/urandom."
    return 1
  fi
  printf '%s' "$pw"
}

# Sets the NSO admin password and saves it to <runtime>/nso-admin.env (mode 600).
# The value is passed to child processes by stdin and environment only, so it
# never appears on a command line, in the log or in script output.
provision_admin_credentials() {
  local runtime_dir="$1" env_file="$1/nso-admin.env" source_desc

  if ! nso_running "$runtime_dir"; then
    if [[ "$ALLOW_DEFAULT_ADMIN" == "true" ]]; then
      log "WARNING: NSO is not running and --insecure-default-admin was given: the NSO default admin password stays in force."
      return 0
    fi
    err "NSO is not running, so the admin password cannot be provisioned and the known NSO default would stay in force."
    err "  Re-run with --start to generate and provision it, or pass --insecure-default-admin for a throwaway development setup."
    return 1
  fi
  require_cmd ncs_load
  require_cmd python3

  if [[ -n "${NSO_ADMIN_PASSWORD:-}" ]]; then
    source_desc="environment"
  elif [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    source "$env_file"
    source_desc="saved file"
  fi
  if [[ -z "${NSO_ADMIN_PASSWORD:-}" ]]; then
    NSO_ADMIN_PASSWORD="$(generate_password)"
    source_desc="generated"
  fi
  if [[ ! "$NSO_ADMIN_PASSWORD" =~ ^[A-Za-z0-9._~@%+=:,#!-]{12,}$ ]]; then
    err "NSO_ADMIN_PASSWORD must be at least 12 characters from A-Z a-z 0-9 . _ ~ @ % + = : , # ! -"
    return 1
  fi
  export NSO_ADMIN_USER NSO_ADMIN_PASSWORD

  # ncs_load hashes the plaintext password as it applies it.
  python3 - <<'PYEOF' | (cd "$runtime_dir" && ncs_load -l -m -u "$NSO_ADMIN_USER" /dev/stdin)
import os
from xml.sax.saxutils import escape
u = escape(os.environ["NSO_ADMIN_USER"])
p = escape(os.environ["NSO_ADMIN_PASSWORD"])
print('<config xmlns="http://tail-f.com/ns/config/1.0"><aaa xmlns="http://tail-f.com/ns/aaa/1.1">'
      '<authentication><users><user><name>' + u + '</name><password>' + p +
      '</password></user></users></authentication></aaa></config>')
PYEOF

  (
    umask 077
    printf 'export NSO_ADMIN_USER=%q\nexport NSO_ADMIN_PASSWORD=%q\n' \
      "$NSO_ADMIN_USER" "$NSO_ADMIN_PASSWORD" > "$env_file"
  )
  chmod 600 "$env_file"
  ADMIN_PROVISIONED="true"
  log "Admin password provisioned (${source_desc}); saved to $env_file (mode 600), value not printed."

  verify_admin_login
}

# Logs in over RESTCONF with the provisioned credentials. Only possible when
# RESTCONF is enabled and reachable; a 401/403 means provisioning did not take effect.
verify_admin_login() {
  if [[ "$ENABLE_RESTCONF" != "true" ]] || ! command -v curl >/dev/null 2>&1; then
    log "Login not verified over RESTCONF (use --enable-restconf to verify)."
    return 0
  fi
  local code="000" i
  for ((i=1; i<=15; i++)); do
    code="$(printf 'user = "%s:%s"\n' "$NSO_ADMIN_USER" "$NSO_ADMIN_PASSWORD" \
      | curl -s -o /dev/null -w '%{http_code}' -K - -H 'Accept: application/yang-data+json' \
          "http://localhost:${RESTCONF_PORT}/restconf/data/tailf-ncs:ncs-state/version" || true)"
    [[ "$code" == "000" ]] || break
    sleep 1
  done
  case "$code" in
    2??) log "Admin login verified over RESTCONF (HTTP $code)." ;;
    401|403) err "RESTCONF rejected the provisioned admin credentials (HTTP $code)."; return 1 ;;
    000) log "RESTCONF not reachable on port ${RESTCONF_PORT}: login not verified (it needs NSO started after --enable-restconf)." ;;
    *) log "RESTCONF login check returned HTTP $code: login not verified." ;;
  esac
}

verify_installation() {
  local install_dir="$1"
  local runtime_dir="$2"
  printf '\n'
  log "=== Verifying NSO Installation ==="

  local errors=0

  # Check install directory
  if [[ ! -d "$install_dir" ]]; then
    err "Install directory missing: $install_dir"
    errors=$((errors + 1))
  else
    log "✓ Install directory exists: $install_dir"
  fi

  # Check ncsrc
  if [[ ! -f "$install_dir/ncsrc" ]]; then
    err "Missing ncsrc file in: $install_dir"
    errors=$((errors + 1))
  else
    log "✓ ncsrc file exists"
  fi

  # Check runtime directory
  if [[ ! -d "$runtime_dir" ]]; then
    err "Runtime directory missing: $runtime_dir"
    errors=$((errors + 1))
  else
    log "✓ Runtime directory exists: $runtime_dir"
  fi

  # Check ncs.conf
  if [[ ! -f "$runtime_dir/ncs.conf" ]]; then
    err "Missing ncs.conf in runtime: $runtime_dir"
    errors=$((errors + 1))
  else
    log "✓ ncs.conf file exists"
  fi

  # Check core binaries
  if ! command -v ncs >/dev/null 2>&1; then
    err "ncs command not available in PATH. Ensure ncsrc is sourced."
    errors=$((errors + 1))
  else
    log "✓ ncs command available"
  fi

  if ! command -v ncs-setup >/dev/null 2>&1; then
    err "ncs-setup command not available in PATH"
    errors=$((errors + 1))
  else
    log "✓ ncs-setup command available"
  fi

  printf '\n'
  if [[ $errors -eq 0 ]]; then
    log "✓ All verification checks passed!"
    return 0
  else
    log "✗ Verification found $errors issue(s). Please review above."
    return 1
  fi
}

# Example name: nso-6.6.darwin.aarch64.installer.bin -> version 6.6
installer_base="$(basename "$INSTALLER_BIN")"
version="$(printf '%s\n' "$installer_base" | sed -n 's/^nso-\([0-9][0-9.]*\)\..*\.installer\.bin$/\1/p')"

if [[ -z "$version" ]]; then
  err "Could not parse NSO version from filename: $installer_base"
  err "Expected pattern like: nso-6.6.darwin.aarch64.installer.bin"
  exit 1
fi

if [[ -z "$INSTALL_DIR" ]]; then
  INSTALL_DIR="$HOME/nso-$version"
fi

if [[ -z "$RUNTIME_DIR" ]]; then
  RUNTIME_DIR="$HOME/nso-run-$version"
fi

INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
RUNTIME_DIR="${RUNTIME_DIR/#\~/$HOME}"
ADMIN_PROVISIONED="false"

log "Installer: $INSTALLER_BIN"
log "Version:   $version"
log "Install:   $INSTALL_DIR"
log "Runtime:   $RUNTIME_DIR"

if [[ -d "$INSTALL_DIR" && -f "$INSTALL_DIR/ncsrc" ]]; then
  log "Existing local install detected at $INSTALL_DIR. Skipping install step."
else
  log "Running local install in home-style directory..."
  sh "$INSTALLER_BIN" "$INSTALL_DIR" --local-install
fi

if [[ ! -f "$INSTALL_DIR/ncsrc" ]]; then
  err "Install appears incomplete: missing $INSTALL_DIR/ncsrc"
  exit 1
fi

# Temporarily disable nounset (-u) because NSO's ncsrc references variables
# (e.g. DYLD_LIBRARY_PATH) that may not be set in a clean environment.
set +u
# shellcheck disable=SC1090
source "$INSTALL_DIR/ncsrc"
set -u

require_cmd ncs-setup
require_cmd ncs

if [[ -f "$RUNTIME_DIR/ncs.conf" ]]; then
  log "Runtime instance already exists at $RUNTIME_DIR. Skipping ncs-setup."
else
  log "Creating runtime instance with ncs-setup --dest ..."
  # Capture ncs-setup exit code without letting set -e abort the script prematurely.
  # ncs-setup occasionally returns non-zero even after successfully creating ncs.conf
  # (e.g. on certain macOS environments). We treat it as success if ncs.conf was written.
  _ncs_setup_exit=0
  ncs-setup --dest "$RUNTIME_DIR" || _ncs_setup_exit=$?
  if [[ $_ncs_setup_exit -ne 0 ]]; then
    if [[ -f "$RUNTIME_DIR/ncs.conf" ]]; then
      log "ncs-setup exited with code $_ncs_setup_exit but ncs.conf was created — continuing."
    else
      err "ncs-setup failed (exit $_ncs_setup_exit) and ncs.conf was not created."
      err "Runtime directory state: $(ls "$RUNTIME_DIR" 2>/dev/null || echo 'empty/missing')"
      exit $_ncs_setup_exit
    fi
  fi
fi

if [[ "$ENABLE_RESTCONF" == "true" ]]; then
  log "Enabling RESTCONF in ncs.conf on port $RESTCONF_PORT ..."
  enable_restconf_in_conf "$RUNTIME_DIR/ncs.conf" "$RESTCONF_PORT"
fi

if [[ "$START_NSO" == "true" ]]; then
  _nso_pid_file="$RUNTIME_DIR/logs/ncs.pid"
  _nso_log="$RUNTIME_DIR/logs/ncs.log"
  # Check if NSO is already running via PID file, or by detecting an ncs process
  # bound to this runtime's ncs.conf (PID file may be absent after an aborted start)
  _nso_running_pid=""
  if [[ -f "$_nso_pid_file" ]] && kill -0 "$(cat "$_nso_pid_file")" 2>/dev/null; then
    _nso_running_pid="$(cat "$_nso_pid_file")"
  else
    # pgrep exits 1 when no match; the || true prevents pipefail from aborting the script
    _nso_running_pid="$(pgrep -f "conffile $RUNTIME_DIR/ncs.conf" 2>/dev/null | head -1 || true)"
  fi
  if [[ -n "$_nso_running_pid" ]]; then
    log "NSO already running (PID $_nso_running_pid) — skipping start."
  else
    log "Starting NSO in runtime directory..."
    # Remove stale PID file only if the process is truly dead
    if [[ -f "$_nso_pid_file" ]] && ! kill -0 "$(cat "$_nso_pid_file")" 2>/dev/null; then
      rm -f "$_nso_pid_file"
    fi
    _nso_exit=0
    (cd "$RUNTIME_DIR" && ncs) || _nso_exit=$?
    # If ncs fails with "einval", the CDB may be corrupt from a previous aborted start.
    # Clear the CDB directory and retry once — safe on a fresh install.
    if [[ $_nso_exit -ne 0 ]] && [[ -f "$_nso_log" ]] && grep -q 'einval' "$_nso_log"; then
      log "Detected 'einval' in ncs.log — clearing CDB and retrying..."
      rm -rf "$RUNTIME_DIR/ncs-cdb"
      mkdir -p "$RUNTIME_DIR/ncs-cdb"
      _nso_exit=0
      (cd "$RUNTIME_DIR" && ncs) || _nso_exit=$?
    fi
    if [[ $_nso_exit -ne 0 ]]; then
      err "ncs exited with status $_nso_exit — daemon failed to start."
      if [[ -f "$_nso_log" ]]; then
        err "Last 20 lines of $( basename "$_nso_log" ):"
        tail -20 "$_nso_log" >&2
      fi
      exit $_nso_exit
    fi
    # ncs --status blocks indefinitely when NSO is not yet running.
    # Poll using three methods in order of reliability:
    #   1. PID file (written by NSO when fully up)
    #   2. pgrep for the ncs process bound to this runtime's ncs.conf
    #   3. "NCS started" line in ncs.log (written just before the PID file)
    _nso_retries=20
    _nso_ok=false
    _nso_detected_pid=""
    for ((_nso_i=1; _nso_i<=_nso_retries; _nso_i++)); do
      if [[ -f "$_nso_pid_file" ]] && kill -0 "$(cat "$_nso_pid_file")" 2>/dev/null; then
        _nso_detected_pid="$(cat "$_nso_pid_file")"
        _nso_ok=true
        break
      fi
      _nso_detected_pid="$(pgrep -f "conffile $RUNTIME_DIR/ncs.conf" 2>/dev/null | head -1 || true)"
      if [[ -n "$_nso_detected_pid" ]]; then
        _nso_ok=true
        break
      fi
      if [[ -f "$_nso_log" ]] && grep -q 'NCS started' "$_nso_log" 2>/dev/null; then
        _nso_detected_pid="$(pgrep -f "ncs.smp" 2>/dev/null | head -1 || true)"
        _nso_ok=true
        break
      fi
      sleep 1
    done
    if [[ "$_nso_ok" == "true" ]]; then
      log "NSO status: started (PID ${_nso_detected_pid:-unknown})"
    else
      err "NSO did not become alive within ${_nso_retries}s — PID file not found, no matching process, and 'NCS started' not seen in log."
      if [[ -f "$_nso_log" ]]; then
        err "Last 20 lines of $( basename "$_nso_log" ):"
        tail -20 "$_nso_log" >&2
      fi
      exit 1
    fi
  fi
fi

provision_admin_credentials "$RUNTIME_DIR"

if [[ "$PERSIST_ENV" == "true" ]]; then
  log "Persisting NSO environment setup to shell profile files..."
  persist_shell_env "$INSTALL_DIR/ncsrc"
  if [[ "$ADMIN_PROVISIONED" == "true" ]]; then
    persist_shell_env "$RUNTIME_DIR/nso-admin.env" optional
  fi
fi

if [[ "$VERIFY" == "true" ]]; then
  verify_installation "$INSTALL_DIR" "$RUNTIME_DIR"
fi

if [[ "$EXPLORE" == "true" ]]; then
  explore_installation "$INSTALL_DIR"
fi

if [[ "$DEV_MODE" == "true" ]]; then
  if [[ "$START_NSO" != "true" ]]; then
    log "Note: --dev-mode requires NSO to be running. Use --start to start NSO, then enable dev mode manually:"
    log "  cd \"$RUNTIME_DIR\" && ncs_cli -u ${NSO_ADMIN_USER} -C 'license smart development enable'"
  else
    enable_dev_mode "$RUNTIME_DIR"
  fi
fi

restconf_note=""
if [[ "$ENABLE_RESTCONF" == "true" ]]; then
  restconf_note="
RESTCONF API (once NSO is running):
  curl -su \"\$NSO_ADMIN_USER:\$NSO_ADMIN_PASSWORD\" -H 'Accept: application/yang-data+json' \\
       http://localhost:${RESTCONF_PORT}/restconf/data

WebUI:
  http://localhost:${RESTCONF_PORT}  (use \$NSO_ADMIN_USER / \$NSO_ADMIN_PASSWORD)

NETCONF over SSH (default):
  ssh -p 2022 ${NSO_ADMIN_USER}@localhost -s netconf
"
fi

if [[ "$ADMIN_PROVISIONED" == "true" ]]; then
  cred_note="
Admin credentials (password is not shown; file mode 600):
  source \"$RUNTIME_DIR/nso-admin.env\"   # exports NSO_ADMIN_USER and NSO_ADMIN_PASSWORD
"
else
  cred_note="
Admin password NOT provisioned (--insecure-default-admin): the NSO default is still in force.
Re-run with --start to generate it.
"
fi

cat <<EOF

Local NSO installation complete.

Install directory : $INSTALL_DIR
Runtime directory : $RUNTIME_DIR

Activate NSO in current shell:
  source "$INSTALL_DIR/ncsrc"

IMPORTANT - always cd into the runtime directory before starting NSO:
  cd "$RUNTIME_DIR" && ncs

Check NSO status:
  cd "$RUNTIME_DIR" && ncs --status | grep status

Stop NSO:
  cd "$RUNTIME_DIR" && ncs --stop
${cred_note}${restconf_note}
NOTE: Running 'ncs' outside the runtime directory will fail with a config error.

EOF
