#!/usr/bin/env bash
# uninstall_mcp.sh — Remove cisco-nso-adaptive-mcp-server from a running NSO instance.
#
# Usage:
#   bash uninstall_mcp.sh [options]
#
# Options:
#   --runtime-dir PATH   Override auto-detected ~/nso-run-<version>
#   --install-dir PATH   Override auto-detected ~/nso-<version>
#   --keep-package       Remove runtime symlink only; keep package in packages/neds/
#   --user USER          NSO admin user for packages reload (default: $NSO_ADMIN_USER env var, else admin)
#   -y, --yes            Skip confirmation prompt

set -euo pipefail

PKG_NAME="cisco-nso-adaptive-mcp-server"

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── path-safety helpers ───────────────────────────────────────────────────────
# Resolve a path to its canonical absolute form (portable; no realpath dependency).
canonicalize() {
    local p="$1" d b
    if [ -d "$p" ]; then
        (cd "$p" 2>/dev/null && pwd -P)
    else
        d=$(dirname "$p"); b=$(basename "$p")
        (cd "$d" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$b")
    fi
}

# Fail unless $1 resolves to a path inside base directory $2 (blocks symlink escapes).
assert_within() {
    local target base
    target=$(canonicalize "$1") || error "Cannot resolve path: $1"
    base=$(canonicalize "$2")   || error "Cannot resolve directory: $2"
    case "$target" in
        "$base"/*|"$base") ;;
        *) error "Refusing to use '$1' — resolves outside expected directory '$2'." ;;
    esac
}

# ── argument parsing ──────────────────────────────────────────────────────────
INSTALL_DIR=""
RUNTIME_DIR=""
KEEP_PACKAGE=false
NSO_USER="${NSO_ADMIN_USER:-admin}"
SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir)  INSTALL_DIR="$2"; shift 2 ;;
        --runtime-dir)  RUNTIME_DIR="$2"; shift 2 ;;
        --keep-package) KEEP_PACKAGE=true; shift ;;
        --user)         NSO_USER="$2"; shift 2 ;;
        -y|--yes)       SKIP_CONFIRM=true; shift ;;
        *) error "Unknown option: $1" ;;
    esac
done

# ── auto-detect NSO directories ───────────────────────────────────────────────
if [ -z "$INSTALL_DIR" ]; then
    INSTALL_DIR=$(ls -d "$HOME"/nso-[0-9]* 2>/dev/null | grep -v 'nso-run' | sort -V | tail -1)
    [ -z "$INSTALL_DIR" ] && error "No NSO install dir found at ~/nso-<version>. Use --install-dir."
fi

if [ -z "$RUNTIME_DIR" ]; then
    RUNTIME_DIR=$(ls -d "$HOME"/nso-run-* 2>/dev/null | sort -V | tail -1)
    [ -z "$RUNTIME_DIR" ] && error "No NSO runtime dir found at ~/nso-run-<version>. Use --runtime-dir."
fi

info "Runtime dir: $RUNTIME_DIR"
info "Install dir: $INSTALL_DIR"

# ── source ncsrc ──────────────────────────────────────────────────────────────
NCSRC="$INSTALL_DIR/ncsrc"
[ -f "$NCSRC" ] || error "ncsrc not found at $NCSRC"
assert_within "$NCSRC" "$INSTALL_DIR"
set +u
# shellcheck source=/dev/null
source "$NCSRC"
set -u

# ── check the package is installed ───────────────────────────────────────────
RUNTIME_SYMLINK="$RUNTIME_DIR/packages/$PKG_NAME"
INSTALL_PKG_DIR="$INSTALL_DIR/packages/neds/$PKG_NAME"

if [ ! -L "$RUNTIME_SYMLINK" ] && [ ! -e "$RUNTIME_SYMLINK" ]; then
    warn "Package '$PKG_NAME' is not currently in the runtime packages directory."
    warn "Nothing to remove from: $RUNTIME_DIR/packages/"
    if [ -d "$INSTALL_PKG_DIR" ] && [ "$KEEP_PACKAGE" = false ]; then
        echo ""
        read -rp "Remove package from install dir ($INSTALL_PKG_DIR) anyway? [y/N] " answer
        case "$answer" in
            [yY]) rm -rf "$INSTALL_PKG_DIR"; info "✓ Removed from install dir."; exit 0 ;;
            *) info "Nothing removed."; exit 0 ;;
        esac
    fi
    exit 0
fi

# ── confirmation prompt ───────────────────────────────────────────────────────
if [ "$SKIP_CONFIRM" = false ]; then
    echo ""
    echo "  This will remove: $RUNTIME_SYMLINK"
    if [ "$KEEP_PACKAGE" = false ] && [ -d "$INSTALL_PKG_DIR" ]; then
        echo "  And delete:       $INSTALL_PKG_DIR"
    fi
    echo "  Then run:         packages reload  (deregisters /mcp endpoint)"
    echo ""
    read -rp "Continue? [y/N] " answer
    case "$answer" in
        [yY]) ;;
        *) info "Aborted."; exit 0 ;;
    esac
fi

# ── remove runtime symlink ────────────────────────────────────────────────────
info "Removing runtime symlink: $RUNTIME_SYMLINK"
rm -f "$RUNTIME_SYMLINK"
info "✓ Runtime symlink removed."

# ── packages reload ───────────────────────────────────────────────────────────
info "Running packages reload — deregisters /mcp Yaws route..."
cd "$RUNTIME_DIR"
RELOAD_OUT=$(echo "packages reload" | ncs_cli -u "$NSO_USER" -C 2>&1)
echo "$RELOAD_OUT"

if echo "$RELOAD_OUT" | grep -q "result false"; then
    warn "packages reload reported a failure for another package. Check NSO logs."
fi
info "✓ Packages reload complete."

# ── remove from install dir ───────────────────────────────────────────────────
if [ "$KEEP_PACKAGE" = false ]; then
    if [ -d "$INSTALL_PKG_DIR" ]; then
        info "Removing package from install dir: $INSTALL_PKG_DIR"
        rm -rf "$INSTALL_PKG_DIR"
        info "✓ Package removed from install dir."
    else
        info "Package not found in install dir (already removed or never extracted there)."
    fi
else
    info "Keeping package in install dir (--keep-package): $INSTALL_PKG_DIR"
    echo ""
    echo "To re-enable later without re-extracting:"
    echo "  ln -sf $INSTALL_PKG_DIR \\"
    echo "         $RUNTIME_DIR/packages/$PKG_NAME"
    echo "  echo 'packages reload' | ncs_cli -u $NSO_USER -C  # run twice"
fi

# ── verify /mcp is gone ───────────────────────────────────────────────────────
# Extract host/port from ncs.conf for verification
NSO_HOST="localhost"
NSO_PORT=$(grep -m1 '<port>' "$RUNTIME_DIR/ncs.conf" 2>/dev/null \
    | grep -A5 'transport' \
    | grep '<port>' | head -1 \
    | sed 's/.*<port>\([0-9]*\)<\/port>.*/\1/' || echo "8080")
# Fallback to 8080 if extraction fails
NSO_PORT="${NSO_PORT:-8080}"

MCP_URL="http://${NSO_HOST}:${NSO_PORT}/mcp"
info "Verifying /mcp endpoint is deregistered: $MCP_URL"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}' \
    "$MCP_URL" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "404" ]; then
    info "✓ /mcp returns 404 — endpoint successfully deregistered."
elif [ "$HTTP_CODE" = "000" ]; then
    warn "Could not reach $MCP_URL — NSO may not be running."
else
    warn "/mcp returned HTTP $HTTP_CODE (expected 404). Route may still be active."
    warn "If route persists, check: $RUNTIME_DIR/logs/cisco-nso-mcp-server.log"
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
info "MCP server removal complete: $PKG_NAME"
if [ "$KEEP_PACKAGE" = true ]; then
    echo "  Package retained at: $INSTALL_PKG_DIR"
fi
