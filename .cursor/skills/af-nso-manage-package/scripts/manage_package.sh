#!/usr/bin/env bash
# manage_package.sh — Scaffold, build, symlink, reload, and remove NSO packages.
#
# Usage:
#   manage_package.sh <package-name> [OPTIONS]
#   manage_package.sh <existing-package-path> --build-only [--reload-packages]
#   manage_package.sh <package-name> --remove [--delete-source]
#
# Scaffold + install modes:
#   manage_package.sh my-svc --type python-and-template --reload-packages
#   manage_package.sh my-svc --type template
#   manage_package.sh my-svc --type java-and-template --augment /ncs:services
#
# Build + reload only (package already exists):
#   manage_package.sh packages/my-svc --build-only --reload-packages
#   manage_package.sh packages/my-svc --build-only --redeploy
#
# Remove a package from NSO (safe order: unload → remove symlink → optionally delete source):
#   manage_package.sh my-svc --remove
#   manage_package.sh my-svc --remove --delete-source
#
# Options:
#   --type TYPE           Service skeleton type (default: python-and-template)
#                         One of: python, python-and-template, java, java-and-template,
#                                 template, nano-python-and-template
#   --dest DIR            packages/ subdirectory destination (default: packages/<name>)
#   --augment PATH        Augment path for service (e.g. /ncs:services)
#   --build-only          Skip scaffold; only build an existing package
#   --reload-packages     Run 'packages reload' in NSO CLI after symlinking
#   --redeploy            Run 'packages package <name> redeploy' (faster, no YANG reload)
#   --remove              Unload from NSO and remove symlink (safe removal)
#   --delete-source       Used with --remove: also delete packages/<name>/ source directory
#   --install-dir PATH    Override auto-detected ~/nso-[0-9]* install dir
#   --runtime-dir PATH    Override auto-detected ~/nso-run-* runtime dir
#   -y / --yes            Skip confirmation prompts

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
PKG_NAME=""
PKG_TYPE="python-and-template"
PKG_DEST=""
AUGMENT_PATH=""
BUILD_ONLY=false
RELOAD_PKGS=false
REDEPLOY=false
REMOVE=false
DELETE_SOURCE=false
YES=false
INSTALL_DIR=""
RUNTIME_DIR=""
# NSO CLI admin identity used for 'packages reload'/'redeploy' — override via env.
NSO_ADMIN_USER="${NSO_ADMIN_USER:-admin}"

# ─── Argument Parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --type)          PKG_TYPE="$2"; shift 2 ;;
    --dest)          PKG_DEST="$2"; shift 2 ;;
    --augment)       AUGMENT_PATH="$2"; shift 2 ;;
    --build-only)    BUILD_ONLY=true; shift ;;
    --reload-packages) RELOAD_PKGS=true; shift ;;
    --redeploy)      REDEPLOY=true; shift ;;
    --remove)        REMOVE=true; shift ;;
    --delete-source) DELETE_SOURCE=true; shift ;;
    --install-dir)   INSTALL_DIR="$2"; shift 2 ;;
    --runtime-dir)   RUNTIME_DIR="$2"; shift 2 ;;
    -y|--yes)        YES=true; shift ;;
    -h|--help)
      sed -n '2,40p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2; exit 1 ;;
    *)
      PKG_NAME="$1"; shift ;;
  esac
done

if [[ -z "$PKG_NAME" ]]; then
  echo "Usage: $0 <package-name|package-path> [OPTIONS]" >&2
  echo "       $0 --help" >&2
  exit 1
fi

# ─── Auto-detect directories ─────────────────────────────────────────────────
if [[ -z "$INSTALL_DIR" ]]; then
  INSTALL_DIR=$(ls -d ~/nso-[0-9]* 2>/dev/null | sort -V | tail -1 || true)
  if [[ -z "$INSTALL_DIR" ]]; then
    echo "ERROR: No NSO install dir found (~/nso-*). Run the af-nso-local-install skill first." >&2
    exit 1
  fi
fi

if [[ -z "$RUNTIME_DIR" ]]; then
  RUNTIME_DIR=$(ls -d ~/nso-run-* 2>/dev/null | sort -V | tail -1 || true)
  if [[ -z "$RUNTIME_DIR" ]]; then
    echo "ERROR: No NSO runtime dir found (~/nso-run-*). Run the af-nso-local-install skill first." >&2
    exit 1
  fi
fi

echo "  Install dir : $INSTALL_DIR"
echo "  Runtime dir : $RUNTIME_DIR"

# ─── Source ncsrc ─────────────────────────────────────────────────────────────
NCSRC="$INSTALL_DIR/ncsrc"
if [[ ! -f "$NCSRC" ]]; then
  echo "ERROR: ncsrc not found at $NCSRC" >&2
  exit 1
fi
set +u
# shellcheck source=/dev/null
source "$NCSRC"
set -u

# ─── NSO running check ────────────────────────────────────────────────────────
# Call this before any operation that requires a live NSO instance.
check_nso_running() {
  local pid_file="$RUNTIME_DIR/logs/ncs.pid"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  # Fallback: ask ncs --status (slower but definitive)
  local ncs_status
  ncs_status=$(ncs --status 2>/dev/null || true)
  if echo "$ncs_status" | grep -q 'status: started'; then
    return 0
  fi
  echo "ERROR: NSO is not running (no live process found for $pid_file)." >&2
  echo "       Start NSO first: ncs --cd $RUNTIME_DIR" >&2
  exit 1
}

# ─── REMOVE ──────────────────────────────────────────────────────────────────
if [[ "$REMOVE" == true ]]; then
  # Resolve the bare package name (strip leading path components if given)
  BARE_NAME=$(basename "$PKG_NAME")
  SYMLINK_TARGET="$RUNTIME_DIR/packages/$BARE_NAME"
  SOURCE_DIR="packages/$BARE_NAME"

  echo ""
  echo "Removing package: $BARE_NAME"

  # Step 1 — Remove symlink from runtime so NSO can unload it on reload
  if [[ -L "$SYMLINK_TARGET" ]]; then
    echo "  Removing symlink: $SYMLINK_TARGET"
    rm "$SYMLINK_TARGET"
  elif [[ -d "$SYMLINK_TARGET" ]]; then
    echo "WARNING: $SYMLINK_TARGET is a real directory (not a symlink)."
    echo "  This may have been copied rather than symlinked."
    if [[ "$YES" == false ]]; then
      read -rp "  Remove it? [y/N] " answer
      [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
    fi
    rm -rf "$SYMLINK_TARGET"
  else
    echo "  No symlink or directory found at $SYMLINK_TARGET — already removed."
  fi

  # Step 2 — Reload NSO so it unloads the package and cleans up its schema
  check_nso_running
  echo ""
  echo "Reloading packages in NSO CLI to unload $BARE_NAME..."
  ncs_cli -u "${NSO_ADMIN_USER}" -C <<'CLICMD'
packages reload
CLICMD

  # Step 3 — Optionally delete the source directory from packages/
  if [[ "$DELETE_SOURCE" == true ]]; then
    if [[ -d "$SOURCE_DIR" ]]; then
      if [[ "$YES" == false ]]; then
        echo ""
        read -rp "  Delete source directory $SOURCE_DIR? [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] || { echo "Source kept. Done."; exit 0; }
      fi
      echo "  Deleting source: $SOURCE_DIR"
      rm -rf "$SOURCE_DIR"
    else
      echo "  Source directory not found at $SOURCE_DIR — skipping."
    fi
  else
    echo ""
    echo "  Source directory kept at: $SOURCE_DIR"
    echo "  Re-run with --delete-source to also remove it."
  fi

  echo ""
  echo "Done. Package $BARE_NAME unloaded from NSO."
  exit 0
fi

# ─── Resolve paths ────────────────────────────────────────────────────────────
# Determine if PKG_NAME is an existing path (build-only) or a name to scaffold
if [[ "$BUILD_ONLY" == true ]]; then
  # PKG_NAME is a path to an existing package
  PKG_PATH="$PKG_NAME"
  if [[ ! -d "$PKG_PATH" ]]; then
    echo "ERROR: Package directory not found: $PKG_PATH" >&2
    exit 1
  fi
  PKG_NAME=$(basename "$PKG_PATH")
  echo "  Package     : $PKG_NAME (existing at $PKG_PATH)"
else
  # Scaffolding a new package
  [[ -z "$PKG_DEST" ]] && PKG_DEST="packages/$PKG_NAME"
  PKG_PATH="$PKG_DEST"
  echo "  Package     : $PKG_NAME → $PKG_PATH"
  echo "  Type        : $PKG_TYPE"
fi

# ─── SCAFFOLD ────────────────────────────────────────────────────────────────
if [[ "$BUILD_ONLY" == false ]]; then
  if [[ -d "$PKG_PATH" ]]; then
    echo ""
    echo "WARNING: $PKG_PATH already exists."
    if [[ "$YES" == false ]]; then
      read -rp "Continue anyway? [y/N] " answer
      [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
    fi
  fi

  # Ensure packages/ dir exists
  mkdir -p "$(dirname "$PKG_PATH")"

  CMD=(ncs-make-package)

  # Map common type aliases
  case "$PKG_TYPE" in
    python|py)                     CMD+=(--service-skeleton python) ;;
    python-and-template|py-tmpl)   CMD+=(--service-skeleton python-and-template) ;;
    template|tmpl)                 CMD+=(--service-skeleton template) ;;
    java)                          CMD+=(--service-skeleton java) ;;
    java-and-template|java-tmpl)   CMD+=(--service-skeleton java-and-template) ;;
    nano-python-and-template|nano) CMD+=(--service-skeleton nano-python-and-template) ;;
    netconf-ned)
      echo "ERROR: For NETCONF NEDs, provide --type netconf-ned and --yang-dir <path> (use ncs-make-package directly)." >&2
      exit 1
      ;;
    *)
      # Pass through unknown types as-is
      CMD+=(--service-skeleton "$PKG_TYPE") ;;
  esac

  [[ -n "$AUGMENT_PATH" ]] && CMD+=(--augment "$AUGMENT_PATH")
  CMD+=(--dest "$PKG_PATH" "$PKG_NAME")

  echo ""
  echo "Creating package scaffold..."
  echo "  ${CMD[*]}"
  echo ""
  "${CMD[@]}"
  echo ""
  echo "Scaffold created at: $PKG_PATH"
fi

# ─── BUILD ────────────────────────────────────────────────────────────────────
SRC_DIR="$PKG_PATH/src"
if [[ ! -f "$SRC_DIR/Makefile" ]]; then
  echo "ERROR: No Makefile found at $SRC_DIR/Makefile" >&2
  exit 1
fi

echo ""
echo "Building package..."
make -C "$SRC_DIR" all
echo "Build complete."

# ─── SYMLINK ─────────────────────────────────────────────────────────────────
RUNTIME_PKG_DIR="$RUNTIME_DIR/packages"
SYMLINK_TARGET="$RUNTIME_PKG_DIR/$PKG_NAME"
ABS_PKG_PATH="$(cd "$PKG_PATH" && pwd)"

if [[ -L "$SYMLINK_TARGET" ]]; then
  echo ""
  echo "Symlink already exists: $SYMLINK_TARGET → $(readlink "$SYMLINK_TARGET")"
  # Update symlink if pointing to a different path
  EXISTING_TARGET=$(readlink "$SYMLINK_TARGET")
  if [[ "$EXISTING_TARGET" != "$ABS_PKG_PATH" ]]; then
    echo "  Updating symlink: $EXISTING_TARGET → $ABS_PKG_PATH"
    ln -sf "$ABS_PKG_PATH" "$SYMLINK_TARGET"
  fi
elif [[ -d "$SYMLINK_TARGET" ]]; then
  echo "WARNING: $SYMLINK_TARGET is a real directory (not a symlink). Skipping symlink creation."
  echo "  Remove it manually and rerun if you want to use the packages/ source directory."
else
  echo ""
  echo "Creating symlink..."
  ln -s "$ABS_PKG_PATH" "$SYMLINK_TARGET"
  echo "  $SYMLINK_TARGET → $ABS_PKG_PATH"
fi

# ─── RELOAD / REDEPLOY ────────────────────────────────────────────────────────
if [[ "$RELOAD_PKGS" == true ]]; then
  check_nso_running
  echo ""
  echo "Running 'packages reload' in NSO CLI..."
  ncs_cli -u "${NSO_ADMIN_USER}" -C <<'CLICMD'
packages reload
CLICMD
  echo ""
  echo "Verifying package status..."
  ncs_cli -u "${NSO_ADMIN_USER}" -C <<CLICMD
show packages package $PKG_NAME
CLICMD
elif [[ "$REDEPLOY" == true ]]; then
  check_nso_running
  echo ""
  echo "Running 'packages package $PKG_NAME redeploy' in NSO CLI..."
  ncs_cli -u "${NSO_ADMIN_USER}" -C <<CLICMD
packages package $PKG_NAME redeploy
CLICMD
  echo ""
  echo "Verifying package status..."
  ncs_cli -u "${NSO_ADMIN_USER}" -C <<CLICMD
show packages package $PKG_NAME
CLICMD
else
  echo ""
  echo "Package installed at: $SYMLINK_TARGET"
  echo "Run 'packages reload' in NSO CLI to activate:"
  echo "  ncs_cli -u ${NSO_ADMIN_USER} -C <<< 'packages reload'"
fi

echo ""
echo "Done."
