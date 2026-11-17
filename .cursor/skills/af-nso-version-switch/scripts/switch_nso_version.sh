#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  switch_nso_version.sh <target-version> [options]

Examples:
  switch_nso_version.sh 6.4.1 --fetch --start --verify --persist-env
  switch_nso_version.sh 6.5.1 --fetch --start --verify --persist-env

Options:
  --fetch             Download the installer for this host before installing
  --start            Start the target runtime after install
  --verify           Verify the runtime after install
  --persist-env      Update shell profile files to source the target ncsrc file
  --install-dir PATH Override install path
  --runtime-dir PATH Override runtime path
  --force            Reinstall even if the target version is already present
  -h, --help         Show this help
EOF
}

log() { printf '[switch_nso_version] %s\n' "$*"; }
err() { printf '[switch_nso_version] ERROR: %s\n' "$*" >&2; }

TARGET_VERSION=""
FETCH_INSTALLER="false"
START_NSO="false"
VERIFY="false"
PERSIST_ENV="false"
FORCE="false"
INSTALL_DIR=""
RUNTIME_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|-v)
      [[ $# -ge 2 ]] || { err "--version requires a value"; exit 1; }
      TARGET_VERSION="$2"
      shift 2
      ;;
    --fetch)
      FETCH_INSTALLER="true"
      shift
      ;;
    --start)
      START_NSO="true"
      shift
      ;;
    --verify)
      VERIFY="true"
      shift
      ;;
    --persist-env)
      PERSIST_ENV="true"
      shift
      ;;
    --install-dir)
      [[ $# -ge 2 ]] || { err "--install-dir requires a value"; exit 1; }
      INSTALL_DIR="$2"
      shift 2
      ;;
    --runtime-dir)
      [[ $# -ge 2 ]] || { err "--runtime-dir requires a value"; exit 1; }
      RUNTIME_DIR="$2"
      shift 2
      ;;
    --force)
      FORCE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$TARGET_VERSION" ]]; then
        TARGET_VERSION="$1"
      else
        err "Unknown argument: $1"
        usage
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$TARGET_VERSION" ]]; then
  err "A target NSO version is required. Example: 6.4.1"
  usage
  exit 1
fi

TARGET_VERSION="${TARGET_VERSION#v}"

if [[ -z "$INSTALL_DIR" ]]; then
  INSTALL_DIR="$HOME/nso-$TARGET_VERSION"
fi
if [[ -z "$RUNTIME_DIR" ]]; then
  RUNTIME_DIR="$HOME/nso-run-$TARGET_VERSION"
fi

INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
RUNTIME_DIR="${RUNTIME_DIR/#\~/$HOME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/../../af-nso-local-install/scripts/install_nso_local.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
  err "Install script not found: $INSTALL_SCRIPT"
  exit 1
fi

stop_running_nso() {
  local runtime_dir
  for runtime_dir in "$HOME"/nso-run-*; do
    [[ -d "$runtime_dir" ]] || continue
    if [[ -f "$runtime_dir/logs/ncs.pid" ]]; then
      local pid
      pid="$(cat "$runtime_dir/logs/ncs.pid" 2>/dev/null || true)"
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        log "Stopping active NSO runtime at $runtime_dir"
        (cd "$runtime_dir" && ncs --stop >/dev/null 2>&1 || true)
      fi
    fi
  done
}

persist_target_ncsrc() {
  local install_dir="$1"
  local profile

  for profile in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile"; do
    [[ -f "$profile" ]] || touch "$profile"
    local tmp
    tmp="$(mktemp)"
    grep -Ev 'source .*nso-[0-9][0-9.]*?/ncsrc|# Added by install_nso_local.sh|# Added by switch_nso_version.sh' "$profile" > "$tmp" || true
    printf '\n# Added by switch_nso_version.sh\nsource "%s/ncsrc"\n' "$install_dir" >> "$tmp"
    mv "$tmp" "$profile"
    log "Updated profile: $profile"
  done
}

log "Requested NSO version: $TARGET_VERSION"
log "Install directory: $INSTALL_DIR"
log "Runtime directory: $RUNTIME_DIR"

stop_running_nso

if [[ "$FORCE" != "true" && -f "$INSTALL_DIR/ncsrc" && -f "$RUNTIME_DIR/ncs.conf" ]]; then
  log "Requested version is already installed and configured: $TARGET_VERSION"
else
  local_cmd=(bash "$INSTALL_SCRIPT" "$TARGET_VERSION")
  if [[ "$FETCH_INSTALLER" == "true" ]]; then
    local_cmd+=(--fetch)
  fi
  if [[ "$PERSIST_ENV" == "true" ]]; then
    local_cmd+=(--persist-env)
  fi
  if [[ "$START_NSO" == "true" ]]; then
    local_cmd+=(--start)
  fi
  if [[ "$VERIFY" == "true" ]]; then
    local_cmd+=(--verify)
  fi
  if [[ -n "$INSTALL_DIR" ]]; then
    local_cmd+=(--install-dir "$INSTALL_DIR")
  fi
  if [[ -n "$RUNTIME_DIR" ]]; then
    local_cmd+=(--runtime-dir "$RUNTIME_DIR")
  fi

  log "Running installer for target version: ${local_cmd[*]}"
  "${local_cmd[@]}"
fi

if [[ "$PERSIST_ENV" == "true" ]]; then
  persist_target_ncsrc "$INSTALL_DIR"
fi

if [[ "$START_NSO" == "true" ]]; then
  log "Switch complete. Active runtime should now be sourced from $INSTALL_DIR/ncsrc"
fi

log "NSO version switch prepared for $TARGET_VERSION"
