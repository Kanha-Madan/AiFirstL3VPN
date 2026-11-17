#!/usr/bin/env bash
# Manage netsim devices for Cisco NSO development.
# Creates/destroys simulated device networks using an installed NED.
# NOTE: --create now automatically deletes any existing netsim setup before creating fresh network.
#
# Usage:
#   netsim_devices.sh [action] [options]

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  netsim_devices.sh <action> [options]

Actions:
  --create               Delete existing netsim (if any) and create fresh network
  --destroy              Stop and delete the entire netsim directory
  --start                Start all netsim devices
  --stop                 Stop all netsim devices
  --restart              Restart all netsim devices
  --list                 List all devices and their ports
  --load                 Generate device XML and load into running NSO (standalone)
  --remove-from-nso      Remove all netsim devices from NSO CDB (standalone)
  --fetch-keys           Fetch SSH host keys for all devices in NSO
  --sync-from            Sync config from all netsim devices into NSO

Modifiers:
  --load-into-nso        Also load devices into NSO after --create
  --remove-from-nso      Also remove devices from NSO CDB after --destroy

Options:
  --ned-dir <path>       Path to NED package dir (required for --create)
  --netsim-dir <path>    Netsim directory (default: <runtime-dir>/netsim)
  --runtime-dir <path>   NSO runtime directory (default: auto-detect $HOME/nso-run-*)
  --install-dir <path>   NSO install directory (default: auto-detect $HOME/nso-*)
  --devices <n>          Number of devices to create (default: 3)
  --prefix <name>        Device name prefix (default: derived from NED name)
  -y, --yes              Skip confirmation prompts
  -h, --help             Show this help

Examples:
  # Create 3 IOS XR netsim devices (deletes any existing setup first)
  netsim_devices.sh --create \
    --ned-dir ~/nso-6.7/packages/neds/cisco-iosxr-cli-7.76 \
    --devices 3 --load-into-nso

  # Recreate with 5 devices (automatically cleans up existing)
  netsim_devices.sh --create \
    --ned-dir ~/nso-6.7/packages/neds/cisco-iosxr-cli-7.76 \
    --devices 5 --load-into-nso

  # Fetch SSH host keys then sync all devices
  netsim_devices.sh --fetch-keys
  netsim_devices.sh --sync-from

  # Manually destroy without recreating
  netsim_devices.sh --destroy --remove-from-nso -y
EOF
}

log() { printf '[INFO] %s\n' "$*"; }
err() { printf '[ERROR] %s\n' "$*" >&2; }

ACTION=""
NED_DIR=""
NETSIM_DIR=""
RUNTIME_DIR=""
INSTALL_DIR=""
NUM_DEVICES="3"
DEVICE_PREFIX=""
LOAD_INTO_NSO="false"
REMOVE_FROM_NSO="false"
ASSUME_YES="false"
# NSO CLI admin identity used for device CDB commands — override via env.
NSO_ADMIN_USER="${NSO_ADMIN_USER:-admin}"

if [[ $# -lt 1 ]]; then
  usage; exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --create)        ACTION="create"; shift ;;
    --destroy)       ACTION="destroy"; shift ;;
    --start)         ACTION="start"; shift ;;
    --stop)          ACTION="stop"; shift ;;
    --restart)       ACTION="restart"; shift ;;
    --list)          ACTION="list"; shift ;;
    --load)             ACTION="load"; shift ;;
    --load-into-nso)    LOAD_INTO_NSO="true"; shift ;;
    --remove-from-nso)  REMOVE_FROM_NSO="true"; shift ;;
    --fetch-keys)       ACTION="fetch-keys"; shift ;;
    --sync-from)        ACTION="sync-from"; shift ;;
    --ned-dir)       [[ $# -ge 2 ]] || { err "--ned-dir needs a value"; exit 1; }
                     NED_DIR="$2"; shift 2 ;;
    --netsim-dir)    [[ $# -ge 2 ]] || { err "--netsim-dir needs a value"; exit 1; }
                     NETSIM_DIR="$2"; shift 2 ;;
    --runtime-dir)   [[ $# -ge 2 ]] || { err "--runtime-dir needs a value"; exit 1; }
                     RUNTIME_DIR="$2"; shift 2 ;;
    --install-dir)   [[ $# -ge 2 ]] || { err "--install-dir needs a value"; exit 1; }
                     INSTALL_DIR="$2"; shift 2 ;;
    --devices)       [[ $# -ge 2 ]] || { err "--devices needs a value"; exit 1; }
                     NUM_DEVICES="$2"; shift 2 ;;
    --prefix)        [[ $# -ge 2 ]] || { err "--prefix needs a value"; exit 1; }
                     DEVICE_PREFIX="$2"; shift 2 ;;
    -y|--yes)        ASSUME_YES="true"; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# --remove-from-nso alone (no other action) is treated as a standalone action
if [[ -z "$ACTION" && "$REMOVE_FROM_NSO" == "true" ]]; then
  ACTION="remove-from-nso"
fi

if [[ -z "$ACTION" ]]; then
  err "No action specified. Use --create, --destroy, --start, --stop, --restart, --list, --load, --remove-from-nso, --fetch-keys, or --sync-from."
  usage; exit 1
fi

# --- Auto-detect directories ---
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

if [[ -z "$NETSIM_DIR" ]]; then
  NETSIM_DIR="$RUNTIME_DIR/netsim"
fi

# --- Source ncsrc ---
set +u
# shellcheck disable=SC1090
source "$INSTALL_DIR/ncsrc"
set -u

# --- Helper: check NSO is running ---
# Uses three methods in order:
#   1. PID file (fast path)
#   2. pgrep for ncs process bound to this runtime's ncs.conf (handles missing PID file)
#   3. NSO IPC port 4569 (final fallback — avoids blocking ncs --status)
nso_is_running() {
  local pid_file="$RUNTIME_DIR/logs/ncs.pid"
  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    return 0
  fi
  if pgrep -f "conffile $RUNTIME_DIR/ncs.conf" >/dev/null 2>&1; then
    return 0
  fi
  nc -z 127.0.0.1 4569 2>/dev/null
}

# --- Helper: derive prefix from NED directory name ---
derive_prefix() {
  local ned_name
  ned_name="$(basename "$1")"
  if   [[ "$ned_name" == *iosxr* ]];  then echo "xr"
  elif [[ "$ned_name" == *ios-cli* ]]; then echo "ios"
  elif [[ "$ned_name" == *nx-cli* ]];  then echo "nx"
  elif [[ "$ned_name" == *asa-cli* ]]; then echo "asa"
  else echo "${ned_name%%-*}"
  fi
}

# ============================================================
# Actions
# ============================================================

case "$ACTION" in

  create)
    if [[ -z "$NED_DIR" ]]; then
      err "--ned-dir is required for --create. Point it at the NED package directory."
      err "Example: ~/nso-6.7/packages/neds/cisco-iosxr-cli-7.76"
      exit 1
    fi
    NED_DIR="${NED_DIR/#\~/$HOME}"
    if [[ ! -f "$NED_DIR/package-meta-data.xml" ]]; then
      err "No package-meta-data.xml found in: $NED_DIR"
      err "Ensure the NED is installed first with install_ned.sh"
      exit 1
    fi

    if [[ -z "$DEVICE_PREFIX" ]]; then
      DEVICE_PREFIX="$(derive_prefix "$NED_DIR")"
    fi

    # Delete existing netsim setup before creating new
    if [[ -d "$NETSIM_DIR" ]]; then
      log "Existing netsim directory detected — removing before creating fresh setup"
      
      # Collect device names for removal from NSO CDB
      NSO_DEVICES=()
      if nso_is_running; then
        while IFS= read -r dev; do
          NSO_DEVICES+=("$dev")
        done < <(ncs-netsim list --dir "$NETSIM_DIR" 2>/dev/null | awk 'NR>2 && /^name=/ {sub(/name=/, ""); sub(/ .*/, ""); print}' || true)
      fi
      
      # Stop netsim devices
      log "Stopping existing netsim devices..."
      ncs-netsim stop --dir "$NETSIM_DIR" 2>/dev/null || true
      
      # Remove devices from NSO CDB if NSO is running
      if nso_is_running && [[ ${#NSO_DEVICES[@]} -gt 0 ]]; then
        log "Removing ${#NSO_DEVICES[@]} device(s) from NSO CDB: ${NSO_DEVICES[*]}"
        CLI_INPUT="config"$'\n'
        for dev in "${NSO_DEVICES[@]}"; do
          CLI_INPUT+="no devices device $dev"$'\n'
        done
        CLI_INPUT+="commit"$'\n'
        printf '%s' "$CLI_INPUT" | ncs_cli -u "${NSO_ADMIN_USER}" -C
        log "✓ Devices removed from NSO CDB."
      fi
      
      # Remove netsim directory
      log "Removing netsim directory: $NETSIM_DIR"
      rm -rf "$NETSIM_DIR"
      log "✓ Existing netsim setup cleaned up."
    fi

    # Create fresh netsim network
    log "Creating fresh netsim network: $NUM_DEVICES x $(basename "$NED_DIR") (prefix: $DEVICE_PREFIX)"
    ncs-netsim create-network "$NED_DIR" "$NUM_DEVICES" "$DEVICE_PREFIX" \
      --dir "$NETSIM_DIR"

    log "Starting netsim devices..."
    if ! ncs-netsim start --dir "$NETSIM_DIR" 2>/dev/null; then
      if ncs-netsim is-alive --dir "$NETSIM_DIR" >/dev/null 2>&1; then
        log "Netsim devices already running — skipping start."
      else
        err "Failed to start netsim devices."; exit 1
      fi
    fi

    printf '\n'
    log "Netsim devices:"
    ncs-netsim list --dir "$NETSIM_DIR"

    if [[ "$LOAD_INTO_NSO" == "true" ]]; then
      log "Generating NSO device init XML..."
      INIT_XML="$(mktemp /tmp/netsim-devices-XXXXXX.xml)"
      # shellcheck disable=SC2064
      trap "rm -f '$INIT_XML'" EXIT
      ncs-netsim --dir "$NETSIM_DIR" ncs-xml-init > "$INIT_XML"

      if nso_is_running; then
        log "Loading devices into running NSO..."
        ncs_load -l -m "$INIT_XML"
        log "✓ Devices loaded."
        log "Next: fetch SSH host keys and sync:"
        log "  $(basename "$0") --fetch-keys"
        log "  $(basename "$0") --sync-from"
      else
        err "NSO is not running — cannot load devices. Start NSO first, then run: $(basename "$0") --load"
        exit 1
      fi
    else
      printf '\n'
      cat <<EOF
Devices created. Next steps:
  # Load devices into NSO
  $(basename "$0") --load

  # Then fetch keys and sync
  $(basename "$0") --fetch-keys
  $(basename "$0") --sync-from
EOF
    fi
    ;;

  destroy)
    if [[ ! -d "$NETSIM_DIR" ]]; then
      log "Netsim directory not found, nothing to destroy: $NETSIM_DIR"
      exit 0
    fi

    if [[ "$ASSUME_YES" != "true" ]]; then
      printf 'This will stop and delete all netsim devices in %s. Continue? [y/N] ' "$NETSIM_DIR"
      read -r answer
      if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        log "Aborted."
        exit 0
      fi
    fi

    # Collect device names before removing the netsim dir
    NSO_DEVICES=()
    if [[ "$REMOVE_FROM_NSO" == "true" ]] && [[ -d "$NETSIM_DIR" ]]; then
      while IFS= read -r dev; do
        NSO_DEVICES+=("$dev")
      done < <(ncs-netsim list --dir "$NETSIM_DIR" 2>/dev/null | awk 'NR>2 && /^name=/ {sub(/name=/, ""); sub(/ .*/, ""); print}' || true)
    fi

    log "Stopping netsim devices..."
    ncs-netsim stop --dir "$NETSIM_DIR" 2>/dev/null || true

    log "Removing netsim directory: $NETSIM_DIR"
    rm -rf "$NETSIM_DIR"
    log "✓ Netsim network destroyed."

    if [[ "$REMOVE_FROM_NSO" == "true" ]]; then
      if [[ ${#NSO_DEVICES[@]} -eq 0 ]]; then
        log "No devices found in netsim list — skipping NSO CDB cleanup."
      elif ! nso_is_running; then
        log "NSO is not running — skipping NSO CDB cleanup."
        log "Manually remove devices: ncs_cli -u ${NSO_ADMIN_USER} -C then 'no devices device <name>; commit'"
      else
        log "Removing ${#NSO_DEVICES[@]} device(s) from NSO CDB: ${NSO_DEVICES[*]}"
        CLI_INPUT="config"$'\n'
        for dev in "${NSO_DEVICES[@]}"; do
          CLI_INPUT+="no devices device $dev"$'\n'
        done
        CLI_INPUT+="commit"$'\n'
        printf '%s' "$CLI_INPUT" | ncs_cli -u "${NSO_ADMIN_USER}" -C
        log "✓ Devices removed from NSO CDB."
      fi
    else
      log "Tip: run --destroy --remove-from-nso to also clean up NSO CDB."
    fi
    ;;

  start)
    if [[ ! -d "$NETSIM_DIR" ]]; then
      err "Netsim directory not found: $NETSIM_DIR"; exit 1
    fi
    log "Starting netsim devices..."
    if ! ncs-netsim start --dir "$NETSIM_DIR" 2>/dev/null; then
      if ncs-netsim is-alive --dir "$NETSIM_DIR" >/dev/null 2>&1; then
        log "Netsim devices already running — skipping start."
      else
        err "Failed to start netsim devices."; exit 1
      fi
    fi
    ;;

  stop)
    if [[ ! -d "$NETSIM_DIR" ]]; then
      err "Netsim directory not found: $NETSIM_DIR"; exit 1
    fi
    log "Stopping netsim devices..."
    ncs-netsim stop --dir "$NETSIM_DIR"
    ;;

  restart)
    if [[ ! -d "$NETSIM_DIR" ]]; then
      err "Netsim directory not found: $NETSIM_DIR"; exit 1
    fi
    log "Restarting netsim devices..."
    ncs-netsim restart --dir "$NETSIM_DIR"
    ;;

  list)
    if [[ ! -d "$NETSIM_DIR" ]]; then
      err "Netsim directory not found: $NETSIM_DIR"; exit 1
    fi
    ncs-netsim list --dir "$NETSIM_DIR"
    ;;

  load)
    if [[ ! -d "$NETSIM_DIR" ]]; then
      err "Netsim directory not found: $NETSIM_DIR"; exit 1
    fi
    if ! nso_is_running; then
      err "NSO is not running. Start NSO first."; exit 1
    fi
    log "Generating NSO device init XML..."
    INIT_XML="$(mktemp /tmp/netsim-devices-XXXXXX.xml)"
    # shellcheck disable=SC2064
    trap "rm -f '$INIT_XML'" EXIT
    ncs-netsim --dir "$NETSIM_DIR" ncs-xml-init > "$INIT_XML"
    log "Loading devices into running NSO..."
    ncs_load -l -m "$INIT_XML"
    log "✓ Devices loaded into NSO CDB."
    ;;

  fetch-keys)
    if ! nso_is_running; then
      err "NSO is not running. Start NSO first."; exit 1
    fi
    log "Fetching SSH host keys for all devices..."
    printf 'devices fetch-ssh-host-keys\n' | ncs_cli -u "${NSO_ADMIN_USER}" -C
    log "✓ SSH host keys updated."
    ;;

  sync-from)
    if ! nso_is_running; then
      err "NSO is not running. Start NSO first."; exit 1
    fi
    log "Syncing config from all devices..."
    printf 'devices sync-from\n' | ncs_cli -u "${NSO_ADMIN_USER}" -C
    log "✓ Sync complete."
    ;;

  remove-from-nso)
    if [[ ! -d "$NETSIM_DIR" ]]; then
      err "Netsim directory not found: $NETSIM_DIR"
      err "Cannot determine device names without netsim directory. Use --netsim-dir if it is in a non-default location."
      exit 1
    fi
    if ! nso_is_running; then
      err "NSO is not running. Start NSO first."; exit 1
    fi

    mapfile -t DEVICES < <(ncs-netsim list --dir "$NETSIM_DIR" 2>/dev/null | awk 'NR>2 && /^name=/ {sub(/name=/, ""); sub(/ .*/, ""); print}' || true)
    if [[ ${#DEVICES[@]} -eq 0 ]]; then
      log "No devices found in netsim list — nothing to remove."
      exit 0
    fi

    log "Removing ${#DEVICES[@]} device(s) from NSO CDB: ${DEVICES[*]}"
    CLI_INPUT="config"$'\n'
    for dev in "${DEVICES[@]}"; do
      CLI_INPUT+="no devices device $dev"$'\n'
    done
    CLI_INPUT+="commit"$'\n'
    printf '%s' "$CLI_INPUT" | ncs_cli -u "${NSO_ADMIN_USER}" -C
    log "✓ Devices removed from NSO CDB."
    ;;

esac
