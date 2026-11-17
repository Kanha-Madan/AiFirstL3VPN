#!/usr/bin/env bash
# Uninstall a Cisco NSO Local Install from the home directory.
# Based on: https://nso-docs.cisco.com/guides/administration/installation-and-deployment/post-install-actions/uninstall-local-install
#
# Usage:
#   uninstall_nso_local.sh [options]
#
# The script will:
#   1. Stop NSO if it is currently running (in the runtime directory)
#   2. Delete the runtime instance directory ($HOME/nso-run-<version>)
#   3. Delete the NSO install directory ($HOME/nso-<version>)
#   4. Remove the 'source ncsrc' lines added to shell profile files

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  uninstall_nso_local.sh [options]

Options:
  --version <ver>        NSO version to uninstall (e.g. 6.7). Auto-detected if omitted.
  --install-dir <path>   NSO install directory (default: $HOME/nso-<version>)
  --runtime-dir <path>   NSO runtime directory (default: $HOME/nso-run-<version>)
  --keep-runtime         Delete install dir but keep the runtime instance directory
  --clean-profiles       Remove 'source ncsrc' lines from ~/.zprofile, ~/.zshrc, ~/.bash_profile
  -y, --yes              Skip confirmation prompt
  -h, --help             Show this help
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

err() {
  printf '[ERROR] %s\n' "$*" >&2
}

VERSION=""
INSTALL_DIR=""
RUNTIME_DIR=""
KEEP_RUNTIME="false"
CLEAN_PROFILES="false"
ASSUME_YES="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || { err "--version needs a value"; exit 1; }
      VERSION="$2"
      shift 2
      ;;
    --install-dir)
      [[ $# -ge 2 ]] || { err "--install-dir needs a value"; exit 1; }
      INSTALL_DIR="$2"
      shift 2
      ;;
    --runtime-dir)
      [[ $# -ge 2 ]] || { err "--runtime-dir needs a value"; exit 1; }
      RUNTIME_DIR="$2"
      shift 2
      ;;
    --keep-runtime)
      KEEP_RUNTIME="true"
      shift
      ;;
    --clean-profiles)
      CLEAN_PROFILES="true"
      shift
      ;;
    -y|--yes)
      ASSUME_YES="true"
      shift
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

# Auto-detect version from $HOME/nso-* if not supplied
if [[ -z "$VERSION" && -z "$INSTALL_DIR" ]]; then
  detected=$(ls -dt "$HOME"/nso-[0-9]* 2>/dev/null | grep -v 'nso-run' | head -n1 || true)
  if [[ -z "$detected" ]]; then
    err "No NSO install directory found under $HOME. Use --version or --install-dir."
    exit 1
  fi
  INSTALL_DIR="$detected"
  VERSION="$(basename "$INSTALL_DIR" | sed 's/^nso-//')"
  log "Auto-detected NSO version: $VERSION at $INSTALL_DIR"
fi

if [[ -z "$INSTALL_DIR" ]]; then
  INSTALL_DIR="$HOME/nso-$VERSION"
fi

if [[ -z "$RUNTIME_DIR" ]]; then
  RUNTIME_DIR="$HOME/nso-run-$VERSION"
fi

# Expand leading ~
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
RUNTIME_DIR="${RUNTIME_DIR/#\~/$HOME}"

log "NSO version:     $VERSION"
log "Install dir:     $INSTALL_DIR"
log "Runtime dir:     $RUNTIME_DIR"
log "Keep runtime:    $KEEP_RUNTIME"
log "Clean profiles:  $CLEAN_PROFILES"

if [[ "$ASSUME_YES" != "true" ]]; then
  printf '\n'
  printf 'This will permanently delete the above directories. Continue? [y/N] '
  read -r answer
  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    log "Aborted."
    exit 0
  fi
fi

# --- Step 1: Stop NSO if running ---
# Check the PID file first — avoids hanging on ncs --status when NSO is not running.
nso_pid_file="$RUNTIME_DIR/logs/ncs.pid"
ncsrc="$INSTALL_DIR/ncsrc"

nso_is_running() {
  if [[ ! -f "$nso_pid_file" ]]; then
    return 1
  fi
  local pid
  pid="$(cat "$nso_pid_file" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

if [[ -f "$ncsrc" ]]; then
  set +u
  # shellcheck disable=SC1090
  source "$ncsrc"
  set -u
  if [[ -f "$RUNTIME_DIR/ncs.conf" ]] && command -v ncs >/dev/null 2>&1; then
    if nso_is_running; then
      log "NSO is running (PID $(cat "$nso_pid_file")). Stopping..."
      (cd "$RUNTIME_DIR" && ncs --stop) || log "NSO stop returned non-zero (may already be stopped)."
    else
      log "NSO is not running. Skipping stop."
    fi
  fi
else
  log "ncsrc not found at $INSTALL_DIR — skipping NSO stop step."
fi

# --- Step 2: Remove runtime directory ---
if [[ "$KEEP_RUNTIME" == "false" ]]; then
  if [[ -d "$RUNTIME_DIR" ]]; then
    log "Removing runtime directory: $RUNTIME_DIR"
    rm -rf "$RUNTIME_DIR"
    log "✓ Runtime directory removed."
  else
    log "Runtime directory not found, skipping: $RUNTIME_DIR"
  fi
else
  log "Keeping runtime directory: $RUNTIME_DIR"
fi

# --- Step 3: Remove install directory ---
if [[ -d "$INSTALL_DIR" ]]; then
  log "Removing install directory: $INSTALL_DIR"
  rm -rf "$INSTALL_DIR"
  log "✓ Install directory removed."
else
  log "Install directory not found, skipping: $INSTALL_DIR"
fi

# --- Step 4: Clean shell profile entries ---
clean_profile() {
  local profile="$1"
  local ncsrc_path="$2"
  local source_line="source \"$ncsrc_path\""
  local cred_file="$RUNTIME_DIR/nso-admin.env"

  if [[ ! -f "$profile" ]]; then
    return 0
  fi

  # Either managed line is enough to require cleanup.
  if ! grep -Fq "$source_line" "$profile" && ! grep -Fq "$cred_file" "$profile"; then
    log "No NSO entry found in $profile. Skipping."
    return 0
  fi

  # Remove the marker comment line (if directly above) and the source line
  # Use a temp file to avoid in-place sed portability issues on macOS
  local tmpfile
  tmpfile="$(mktemp)"
  grep -Fv "$source_line" "$profile" \
    | grep -Fv "$cred_file" \
    | grep -Fv "# Added by install_nso_local.sh" \
    > "$tmpfile" || true
  mv "$tmpfile" "$profile"
  log "✓ Removed NSO entry from $profile"
}

if [[ "$CLEAN_PROFILES" == "true" ]]; then
  log "Cleaning NSO entries from shell profile files..."
  ncsrc_path="$INSTALL_DIR/ncsrc"
  for profile in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile"; do
    clean_profile "$profile" "$ncsrc_path"
  done
fi

printf '\n'
log "NSO $VERSION local uninstall complete."
printf '\n'
printf 'Open a new terminal (or run: exec zsh) for PATH changes to take effect.\n'
