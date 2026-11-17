#!/usr/bin/env bash
# install_mcp.sh — Install cisco-nso-adaptive-mcp-server into a running NSO instance.
#
# Usage:
#   bash install_mcp.sh [path-to-signed.bin-or-tarball | vendor-slug] [options]
#
# The bundle can be a local file, or a vendor slug resolved from the shared XDG
# binary store via fetch_ned.sh (reuses an existing download or fetches one). With
# no positional (or --fetch), the default slug cisco-nso-adaptive-mcp-server is used.
#
# Options:
#   --fetch              Resolve from the shared store even if the argument looks like a path
#   --nso-version VER    NSO version used to resolve the package (default: auto-detect)
#   --install-dir PATH   Override auto-detected ~/nso-<version>
#   --runtime-dir PATH   Override auto-detected ~/nso-run-<version>
#   --host HOST          NSO host for /mcp verification (default: localhost)
#   --port PORT          NSO WebUI port for /mcp verification (default: 8080)
#   --user USER          NSO admin user (default: $NSO_ADMIN_USER env var, else admin)
#   --pass PASS          NSO admin password (required: $NSO_ADMIN_PASSWORD env var or --pass)

set -euo pipefail

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

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
NSO_HOST="localhost"
NSO_PORT="8080"
NSO_USER="${NSO_ADMIN_USER:-admin}"
NSO_PASS="${NSO_ADMIN_PASSWORD:-}"
FETCH_MODE="false"
NSO_VERSION_REQ=""
# Default MCP package slug on dl.tail-f.com, used when no bundle/slug is given.
MCP_SLUG="cisco-nso-adaptive-mcp-server"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH_NED="$SCRIPT_DIR/../../af-nso-install-ned/scripts/fetch_ned.sh"

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --runtime-dir) RUNTIME_DIR="$2"; shift 2 ;;
        --host)        NSO_HOST="$2";   shift 2 ;;
        --port)        NSO_PORT="$2";   shift 2 ;;
        --user)        NSO_USER="$2";   shift 2 ;;
        --pass)        NSO_PASS="$2";   shift 2 ;;
        --nso-version) NSO_VERSION_REQ="$2"; shift 2 ;;
        --fetch)       FETCH_MODE="true"; shift ;;
        -*) error "Unknown option: $1" ;;
        *)  POSITIONAL+=("$1"); shift ;;
    esac
done

MCP_FILE="${POSITIONAL[0]:-}"

[ -z "$NSO_PASS" ] && error "NSO admin password not set. Export NSO_ADMIN_PASSWORD or pass --pass PASS."

# ── resolve the MCP bundle ────────────────────────────────────────────────────
# A local bundle is an existing .signed.bin/.tar.gz/.tgz file; otherwise (or with
# --fetch) the argument is treated as a vendor slug and resolved from the shared
# XDG binary store via fetch_ned.sh, which reuses an existing download or fetches
# one. With no positional, the default MCP slug is used.
if [ "$FETCH_MODE" != "true" ] && [ -n "$MCP_FILE" ] && [ -f "$MCP_FILE" ]; then
    : # local bundle provided
else
    SLUG="${MCP_FILE:-$MCP_SLUG}"
    [ -x "$FETCH_NED" ] || error "Cannot resolve MCP package: $FETCH_NED not found or not executable"
    info "Resolving MCP package from shared store ($SLUG) ..."
    fetch_args=("$SLUG")
    [ -n "$NSO_VERSION_REQ" ] && fetch_args+=(--nso-version "$NSO_VERSION_REQ")
    MCP_FILE=$("$FETCH_NED" "${fetch_args[@]}" | tail -1)
    { [ -n "$MCP_FILE" ] && [ -f "$MCP_FILE" ]; } || error "MCP package resolve/download failed for '$SLUG'."
    info "Using MCP bundle: $MCP_FILE"
fi

# ── validate input file ───────────────────────────────────────────────────────
[ -f "$MCP_FILE" ] || error "File not found: $MCP_FILE"
case "$MCP_FILE" in
    *.signed.bin|*.tar.gz|*.tgz) ;;
    *) error "Unsupported file type. Expected .signed.bin, .tar.gz, or .tgz — got: $MCP_FILE" ;;
esac

# Canonicalize to an absolute real path so later execution isn't redirected by symlinks.
MCP_FILE=$(canonicalize "$MCP_FILE")
[ -f "$MCP_FILE" ] || error "File not found after resolving path: $MCP_FILE"

MCP_BASENAME=$(basename "$MCP_FILE")
info "Processing: $MCP_BASENAME"

# ── auto-detect NSO directories ───────────────────────────────────────────────
if [ -z "$INSTALL_DIR" ]; then
    INSTALL_DIR=$(ls -d "$HOME"/nso-[0-9]* 2>/dev/null | grep -v 'nso-run' | sort -V | tail -1)
    [ -z "$INSTALL_DIR" ] && error "No NSO install dir found at ~/nso-<version>. Use --install-dir."
fi

if [ -z "$RUNTIME_DIR" ]; then
    RUNTIME_DIR=$(ls -d "$HOME"/nso-run-* 2>/dev/null | sort -V | tail -1)
    [ -z "$RUNTIME_DIR" ] && error "No NSO runtime dir found at ~/nso-run-<version>. Use --runtime-dir."
fi

info "Install dir:  $INSTALL_DIR"
info "Runtime dir:  $RUNTIME_DIR"

# ── source ncsrc ──────────────────────────────────────────────────────────────
NCSRC="$INSTALL_DIR/ncsrc"
[ -f "$NCSRC" ] || error "ncsrc not found at $NCSRC"
assert_within "$NCSRC" "$INSTALL_DIR"
set +u
# shellcheck source=/dev/null
source "$NCSRC"
set -u

# ── extract signed bundle ─────────────────────────────────────────────────────
TARBALL=""
EXTRACT_DIR=""

cleanup() { [ -n "$EXTRACT_DIR" ] && rm -rf "$EXTRACT_DIR"; }
trap cleanup EXIT

case "$MCP_FILE" in
    *.signed.bin)
        EXTRACT_DIR=$(mktemp -d)
        assert_within "$EXTRACT_DIR" "${TMPDIR:-/tmp}"
        info "Verifying and extracting signed bundle: $MCP_BASENAME"
        [ -f "$MCP_FILE" ] || error "Signed bundle missing before extraction: $MCP_FILE"
        (cd "$EXTRACT_DIR" && sh "$MCP_FILE") || error "Extraction/verification failed."
        TARBALL=$(ls "$EXTRACT_DIR"/*.tar.gz 2>/dev/null | head -1)
        [ -z "$TARBALL" ] && error "No .tar.gz found after extracting $MCP_BASENAME"
        ;;
    *.tar.gz|*.tgz)
        TARBALL="$MCP_FILE"
        ;;
esac

info "Tarball: $(basename "$TARBALL")"

# ── get package name from tarball (reliable — no filesystem scanning) ─────────
PKG_NAME=$(tar -tzf "$TARBALL" | head -1 | tr -d '/')
[ -z "$PKG_NAME" ] && error "Could not determine package name from tarball."
info "Package name: $PKG_NAME"

# ── install into packages/neds ────────────────────────────────────────────────
NEDS_DIR="$INSTALL_DIR/packages/neds"
mkdir -p "$NEDS_DIR"

info "Installing package into: $NEDS_DIR"
tar -zxf "$TARBALL" -C "$NEDS_DIR"

[ -d "$NEDS_DIR/$PKG_NAME" ] || error "Expected package dir not found after extraction: $NEDS_DIR/$PKG_NAME"
info "✓ Package extracted: $NEDS_DIR/$PKG_NAME"

# ── symlink into runtime packages ─────────────────────────────────────────────
RUNTIME_PKGS="$RUNTIME_DIR/packages"
mkdir -p "$RUNTIME_PKGS"

SYMLINK="$RUNTIME_PKGS/$PKG_NAME"
if [ -L "$SYMLINK" ] || [ -e "$SYMLINK" ]; then
    info "Symlink already exists — updating."
    rm -f "$SYMLINK"
fi

ln -sf "$NEDS_DIR/$PKG_NAME" "$SYMLINK"
info "✓ Symlink created: $SYMLINK -> $NEDS_DIR/$PKG_NAME"

# ── first packages reload ─────────────────────────────────────────────────────
info "First packages reload — loads schema, starts Java backend and Unix socket..."
cd "$RUNTIME_DIR"
RELOAD_OUT=$(echo "packages reload" | ncs_cli -u "$NSO_USER" -C 2>&1)
echo "$RELOAD_OUT"

if echo "$RELOAD_OUT" | grep -q "result false"; then
    error "packages reload (1st) reported failure. Check NSO logs."
fi
info "✓ First reload complete."

# ── second packages reload ────────────────────────────────────────────────────
info "Second packages reload — triggers Yaws /mcp route registration..."
RELOAD_OUT2=$(echo "packages reload" | ncs_cli -u "$NSO_USER" -C 2>&1)
echo "$RELOAD_OUT2"

if echo "$RELOAD_OUT2" | grep -q "result false"; then
    error "packages reload (2nd) reported failure. Check NSO logs."
fi
info "✓ Second reload complete."

# ── verify /mcp endpoint ──────────────────────────────────────────────────────
MCP_URL="http://${NSO_HOST}:${NSO_PORT}/mcp"
info "Verifying MCP endpoint: $MCP_URL"

INIT_PAYLOAD='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"install-verify","version":"1.0"}}}'

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${NSO_USER}:${NSO_PASS}" \
    -H "Content-Type: application/json" \
    -d "$INIT_PAYLOAD" \
    "$MCP_URL" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
    info "✓ MCP endpoint is responding (HTTP $HTTP_CODE)."
else
    warn "MCP endpoint returned HTTP $HTTP_CODE — expected 200."
    warn "Check logs: $RUNTIME_DIR/logs/cisco-nso-mcp-server.log"
    warn "  and:      $RUNTIME_DIR/logs/ncs-java-vm.log"
    warn "Common fix: if HTTP 404, run 'packages reload' once more."
    exit 1
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
info "MCP server installation complete: $PKG_NAME"
echo ""
echo "  Endpoint: $MCP_URL"
echo "  Auth:     Basic (NSO credentials)"
echo ""
echo "Quick test:"
echo "  curl -u ${NSO_USER}:${NSO_PASS} -H 'Content-Type: application/json' \\"
echo "    -d '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}' \\"
echo "    $MCP_URL"
echo ""
echo "Full smoke test (bundled with package):"
echo "  bash $NEDS_DIR/$PKG_NAME/test-mcp.sh"
