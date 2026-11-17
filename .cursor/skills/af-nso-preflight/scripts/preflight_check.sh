#!/usr/bin/env bash
# preflight_check.sh — read-only NSO developer-environment readiness check.
#
# Verifies, without changing anything, that the environment is ready for NSO
# work: NSO installed, NSO running, RESTCONF reachable, and NED-download
# credentials present in the macOS Keychain. It NEVER installs, starts, stops,
# or edits anything — remediation is the caller's job (delegate to
# af-nso-local-install). It also never touches the AI primitives.
#
# Output: one line per check ([OK]/[GAP]/[--]) plus a final machine-parseable
# summary line `PREFLIGHT: READY` or `PREFLIGHT: GAPS=<n>`.
# Exit codes: 0 = ready, 3 = one or more gaps, 2 = usage/internal.
#
# IMPORTANT: never call `ncs --status` — it blocks indefinitely when NSO is
# down. Running state is detected via the PID file / process match instead.

set -uo pipefail   # deliberately NOT -e: every check must run to completion.

RESTCONF_PORT="${NSO_RESTCONF_PORT:-8080}"
RESTCONF_HOST="${NSO_HOST:-localhost}"
GAPS=0
ok()   { printf '[OK]  %s\n' "$*"; }
gap()  { printf '[GAP] %s\n' "$*"; GAPS=$((GAPS+1)); }
skip() { printf '[--]  %s\n' "$*"; }

# --- 1. NSO installed --------------------------------------------------------
INSTALL_DIR="$(ls -d "$HOME"/nso-[0-9]* 2>/dev/null | sort -V | tail -1 || true)"
NCS_BIN=""
if command -v ncs >/dev/null 2>&1; then
  NCS_BIN="$(command -v ncs)"
elif [[ -n "$INSTALL_DIR" && -x "$INSTALL_DIR/bin/ncs" ]]; then
  NCS_BIN="$INSTALL_DIR/bin/ncs"
fi

if [[ -n "$NCS_BIN" ]]; then
  ver="$("$NCS_BIN" --version 2>/dev/null || echo '?')"
  ok "NSO installed: ${INSTALL_DIR:-$(dirname "$(dirname "$NCS_BIN")")} (ncs $ver)"
else
  gap "NSO not installed (no ~/nso-<ver> and 'ncs' not on PATH) — install via af-nso-local-install"
fi

# --- 2. NSO running (PID file / process match; never `ncs --status`) ---------
RUNTIME_DIR="$(ls -d "$HOME"/nso-run-[0-9]* 2>/dev/null | sort -V | tail -1 || true)"
running_pid=""
if [[ -n "$RUNTIME_DIR" && -f "$RUNTIME_DIR/logs/ncs.pid" ]]; then
  pid="$(cat "$RUNTIME_DIR/logs/ncs.pid" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    running_pid="$pid"
  fi
fi
if [[ -z "$running_pid" && -n "$RUNTIME_DIR" ]]; then
  running_pid="$(pgrep -f "conffile $RUNTIME_DIR/ncs.conf" 2>/dev/null | head -1 || true)"
fi

if [[ -n "$running_pid" ]]; then
  ok "NSO running (PID $running_pid, runtime ${RUNTIME_DIR:-?})"
elif [[ -n "$NCS_BIN" ]]; then
  gap "NSO installed but not running — start it (cd ${RUNTIME_DIR:-~/nso-run-<ver>} && ncs) or use af-nso-local-install --start"
else
  skip "NSO running: skipped (not installed)"
fi

# --- 3. RESTCONF reachable ---------------------------------------------------
if [[ -n "$running_pid" ]]; then
  code="$(curl -s -o /dev/null -m 4 -w '%{http_code}' \
    "http://${RESTCONF_HOST}:${RESTCONF_PORT}/restconf" 2>/dev/null || echo 000)"
  case "$code" in
    2??|401) ok "RESTCONF reachable on :${RESTCONF_PORT} (HTTP $code)" ;;
    000)     gap "RESTCONF not reachable on :${RESTCONF_PORT} — enable it (af-nso-local-install --enable-restconf) and restart NSO" ;;
    *)       gap "RESTCONF returned HTTP $code on :${RESTCONF_PORT} — check ncs.conf <restconf> block" ;;
  esac
else
  skip "RESTCONF: skipped (NSO not running)"
fi

# --- 4. NED-download credentials in Keychain (macOS) -------------------------
if [[ "$(uname -s)" == "Darwin" ]]; then
  if security find-internet-password -s dl.tail-f.com >/dev/null 2>&1; then
    ok "NED-download credentials present in Keychain (dl.tail-f.com)"
  else
    gap "No dl.tail-f.com credentials in Keychain — first NED/MCP download will prompt (stored securely, never written to disk)"
  fi
else
  skip "NED-download credentials: Linux prompts per-run (no Keychain check)"
fi

# --- Summary -----------------------------------------------------------------
printf '\n'
if [[ "$GAPS" -eq 0 ]]; then
  echo "PREFLIGHT: READY"
  exit 0
fi
echo "PREFLIGHT: GAPS=$GAPS"
exit 3
