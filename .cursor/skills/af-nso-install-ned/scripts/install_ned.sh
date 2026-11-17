#!/usr/bin/env bash
# Install a Cisco NSO NED from a signed.bin or tar.gz, add a symlink to the
# runtime packages directory, and optionally reload packages in a running NSO.
#
# The NED artifact can be a local file, or a vendor slug (e.g. cisco-iosxr)
# resolved from the shared XDG binary store via fetch_ned.sh — which reuses an
# already-downloaded bundle or downloads one into the store if missing.
#
# For creating/managing netsim devices, use netsim_devices.sh after this script.
#
# Usage:
#   install_ned.sh <ned-file.signed.bin|ned-file.tar.gz> [options]
#   install_ned.sh <vendor-slug> [ned-version] [options]

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  install_ned.sh <ned.signed.bin | ned.tar.gz> [options]   # install a local artifact
  install_ned.sh <vendor-slug> [ned-version] [options]     # resolve/fetch from the store

Options:
  --fetch                Resolve the NED from the shared store even if the first
                         argument looks like a path
  --nso-version <ver>    NSO version used to resolve the NED (default: auto-detect)
  --install-dir <path>   NSO install directory (default: auto-detect $HOME/nso-*)
  --runtime-dir <path>   NSO runtime directory (default: auto-detect $HOME/nso-run-*)
  --reload-packages      Reload NSO packages after installing (requires NSO running)
  -h, --help             Show this help

The shared store defaults to ${XDG_DATA_HOME:-$HOME/.local/share}/aifirst/binaries/neds
and honors AIFIRST_HOME / AIFIRST_BINARIES_DIR (see fetch_ned.sh).

Examples:
  # Install a local NED artifact
  install_ned.sh ~/Downloads/ncs-6.7-cisco-iosxr-7.76.3.signed.bin

  # Resolve from the shared store (reuse if present, else download), then install
  install_ned.sh cisco-iosxr

  # Pin a NED version and reload packages in running NSO
  install_ned.sh cisco-iosxr 7.76.3 --reload-packages
EOF
}

log() { printf '[INFO] %s\n' "$*"; }
err() { printf '[ERROR] %s\n' "$*" >&2; }

NED_FILE=""
INSTALL_DIR=""
RUNTIME_DIR=""
RELOAD_PACKAGES="false"
FETCH_MODE="false"
NSO_VERSION_REQ=""
# NSO CLI admin identity used for 'packages reload' — override via env.
NSO_ADMIN_USER="${NSO_ADMIN_USER:-admin}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH_NED="$SCRIPT_DIR/fetch_ned.sh"

if [[ $# -lt 1 ]]; then
  usage; exit 1
fi

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)   [[ $# -ge 2 ]] || { err "--install-dir needs a value"; exit 1; }
                     INSTALL_DIR="$2"; shift 2 ;;
    --runtime-dir)   [[ $# -ge 2 ]] || { err "--runtime-dir needs a value"; exit 1; }
                     RUNTIME_DIR="$2"; shift 2 ;;
    --nso-version)   [[ $# -ge 2 ]] || { err "--nso-version needs a value"; exit 1; }
                     NSO_VERSION_REQ="$2"; shift 2 ;;
    --fetch)         FETCH_MODE="true"; shift ;;
    --reload-packages) RELOAD_PACKAGES="true"; shift ;;
    -h|--help)       usage; exit 0 ;;
    -*) err "Unknown option: $1"; usage; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

ARG1="${POSITIONAL[0]:-}"
ARG2="${POSITIONAL[1]:-}"
if [[ -z "$ARG1" ]]; then
  usage; exit 1
fi

# --- Resolve the NED artifact ---
# A local artifact is an existing .signed.bin/.tar.gz/.tgz file; anything else
# (e.g. a vendor slug like "cisco-iosxr") is resolved from the shared XDG binary
# store via fetch_ned.sh, which reuses an existing download or fetches one.
if [[ "$FETCH_MODE" != "true" && -f "$ARG1" ]]; then
  NED_FILE="$ARG1"
else
  if [[ ! -x "$FETCH_NED" ]]; then
    err "Cannot resolve NED: $FETCH_NED not found or not executable"; exit 1
  fi
  log "Resolving NED from shared store (${ARG1}${ARG2:+ $ARG2}) ..."
  fetch_args=("$ARG1")
  [[ -n "$ARG2" ]] && fetch_args+=("$ARG2")
  [[ -n "$NSO_VERSION_REQ" ]] && fetch_args+=(--nso-version "$NSO_VERSION_REQ")
  NED_FILE="$("$FETCH_NED" "${fetch_args[@]}" | tail -1)"
  if [[ -z "$NED_FILE" || ! -f "$NED_FILE" ]]; then
    err "NED resolve/download failed for '$ARG1'."; exit 1
  fi
  log "Using NED artifact: $NED_FILE"
fi

# --- Validate input file ---
if [[ ! -f "$NED_FILE" ]]; then
  err "NED file not found: $NED_FILE"; exit 1
fi

NED_FILE_BASE="$(basename "$NED_FILE")"
case "$NED_FILE_BASE" in
  *.signed.bin|*.tar.gz|*.tgz) ;;
  *) err "Expected a .signed.bin or .tar.gz file. Got: $NED_FILE_BASE"; exit 1 ;;
esac

# --- Auto-detect install and runtime dirs ---
if [[ -z "$INSTALL_DIR" ]]; then
  INSTALL_DIR="$(ls -dt "$HOME"/nso-[0-9]* 2>/dev/null | grep -v 'nso-run' | head -n1 || true)"
  if [[ -z "$INSTALL_DIR" ]]; then
    err "Could not auto-detect NSO install directory. Use --install-dir."
    exit 1
  fi
  log "Auto-detected install dir: $INSTALL_DIR"
fi

if [[ -z "$RUNTIME_DIR" ]]; then
  RUNTIME_DIR="$(ls -dt "$HOME"/nso-run-* 2>/dev/null | head -n1 || true)"
  if [[ -z "$RUNTIME_DIR" ]]; then
    err "Could not auto-detect NSO runtime directory. Use --runtime-dir."
    exit 1
  fi
  log "Auto-detected runtime dir: $RUNTIME_DIR"
fi

INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
RUNTIME_DIR="${RUNTIME_DIR/#\~/$HOME}"
NEDS_DIR="$INSTALL_DIR/packages/neds"

if [[ ! -d "$NEDS_DIR" ]]; then
  log "Creating NED packages directory: $NEDS_DIR"
  mkdir -p "$NEDS_DIR"
fi

# --- Source ncsrc ---
set +u
# shellcheck disable=SC1090
source "$INSTALL_DIR/ncsrc"
set -u

# --- Step 1: Extract signed.bin if needed ---
NED_TARBALL=""
if [[ "$NED_FILE_BASE" == *.signed.bin ]]; then
  log "Verifying and extracting signed NED: $NED_FILE_BASE"
  EXTRACT_DIR="$(mktemp -d)"
  trap 'rm -rf "$EXTRACT_DIR"' EXIT

  # Extract in a temp dir to avoid polluting Downloads with cert files
  (cd "$EXTRACT_DIR" && sh "$NED_FILE")

  NED_TARBALL="$(ls "$EXTRACT_DIR"/*.tar.gz 2>/dev/null | head -n1 || true)"
  if [[ -z "$NED_TARBALL" ]]; then
    err "No .tar.gz found after extracting signed.bin. Extraction may have failed."
    exit 1
  fi
  log "Extracted tarball: $(basename "$NED_TARBALL")"
else
  NED_TARBALL="$NED_FILE"
fi

# --- Step 2: Extract NED tarball into neds directory ---
log "Installing NED into: $NEDS_DIR"
tar -zxf "$NED_TARBALL" -C "$NEDS_DIR"

# Derive the NED package name directly from the tarball contents.
# Using ls -dt (modification time) is racy when two installs run in parallel —
# both scripts would pick whichever package-meta-data.xml is newest on disk,
# which may belong to the other parallel install.
NED_PKG_NAME="$(tar -tzf "$NED_TARBALL" 2>/dev/null \
  | grep -m1 'package-meta-data\.xml' | cut -d/ -f1 || true)"
if [[ -z "$NED_PKG_NAME" ]]; then
  # Fallback: first top-level directory in the tarball
  NED_PKG_NAME="$(tar -tzf "$NED_TARBALL" 2>/dev/null | head -n1 | cut -d/ -f1 || true)"
fi

NED_PKG_DIR="$NEDS_DIR/$NED_PKG_NAME"

if [[ -z "$NED_PKG_NAME" || ! -d "$NED_PKG_DIR" ]]; then
  err "Could not locate installed NED package directory under $NEDS_DIR"
  exit 1
fi

log "Installed NED package: $NED_PKG_NAME"

# --- Step 3: Symlink NED into runtime packages ---
RUNTIME_PKGS="$RUNTIME_DIR/packages"
mkdir -p "$RUNTIME_PKGS"

SYMLINK="$RUNTIME_PKGS/$NED_PKG_NAME"
if [[ -L "$SYMLINK" ]]; then
  log "Symlink already exists: $SYMLINK — updating."
  rm "$SYMLINK"
fi
ln -sf "$NED_PKG_DIR" "$SYMLINK"
log "✓ Symlink created: $SYMLINK -> $NED_PKG_DIR"

# --- Step 4: Reload packages in NSO (if requested and NSO is running) ---
if [[ "$RELOAD_PACKAGES" == "true" ]]; then
  nso_pid_file="$RUNTIME_DIR/logs/ncs.pid"
  nso_running=false
  if [[ -f "$nso_pid_file" ]] && kill -0 "$(cat "$nso_pid_file")" 2>/dev/null; then
    nso_running=true
  elif pgrep -f "conffile $RUNTIME_DIR/ncs.conf" >/dev/null 2>&1; then
    nso_running=true
  elif nc -z 127.0.0.1 4569 2>/dev/null; then
    nso_running=true
  fi

  if [[ "$nso_running" == "true" ]]; then
    log "Reloading NSO packages..."
    printf 'packages reload\n' | ncs_cli -u "${NSO_ADMIN_USER}" -C || {
      err "Package reload failed. You may need to restart NSO manually."
    }
    log "✓ Packages reloaded."
  else
    log "NSO is not running — skipping package reload. Packages will load on next NSO start."
  fi
fi

printf '\n'
log "NED installation complete: $NED_PKG_NAME"
printf '\n'
cat <<EOF
Next step — create netsim devices:
  ./scripts/netsim_devices.sh --ned-dir "$NED_PKG_DIR" --create --devices 3

NSO CLI:
  cd "$RUNTIME_DIR" && ncs_cli -u "${NSO_ADMIN_USER}" -C
EOF
