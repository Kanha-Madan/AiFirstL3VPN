#!/usr/bin/env bash
#
# ensure_venv.sh — idempotent bootstrap of this repo's shared Python virtualenv.
#
# Creates a gitignored .venv/ at the repo root and installs the committed recipe
# (agent_primitives/requirements.txt). Safe and fast to call from any skill or
# script: it only (re)installs when the venv is missing or the recipe changed,
# and is otherwise a no-op.
#
# Usage:
#   # As a helper that sets $PY for the current shell:
#   source scripts/ensure_venv.sh
#   "$PY" my_script.py
#
#   # Or executed directly; prints the interpreter path on stdout:
#   PY="$(scripts/ensure_venv.sh)"
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${ROOT_DIR}/.venv"
REQ_FILE="${ROOT_DIR}/agent_primitives/requirements.txt"
STAMP_FILE="${VENV_DIR}/.requirements.sha256"
PYTHON_BIN="${VENV_DIR}/bin/python"

_ensure_venv_hash_reqs() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$REQ_FILE" | awk '{print $1}'
  else
    sha256sum "$REQ_FILE" | awk '{print $1}'
  fi
}

if [[ ! -f "$REQ_FILE" ]]; then
  echo "ensure_venv: missing recipe $REQ_FILE" >&2
  exit 1
fi

# Create the virtualenv on first run.
if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "ensure_venv: creating virtualenv at $VENV_DIR" >&2
  python3 -m venv "$VENV_DIR"
fi

# Reinstall only when the recipe changed (or on first run).
want_hash="$(_ensure_venv_hash_reqs)"
have_hash=""
[[ -f "$STAMP_FILE" ]] && have_hash="$(cat "$STAMP_FILE")"

if [[ "$want_hash" != "$have_hash" ]]; then
  echo "ensure_venv: installing requirements (first run or recipe changed)" >&2
  "$PYTHON_BIN" -m pip install --quiet --upgrade pip
  "$PYTHON_BIN" -m pip install --quiet -r "$REQ_FILE"
  printf '%s\n' "$want_hash" > "$STAMP_FILE"
else
  echo "ensure_venv: up to date (no changes)" >&2
fi

# Expose the interpreter path to callers that `source` this script.
PY="$PYTHON_BIN"
export PY

# When executed directly (not sourced), print the interpreter path on stdout.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "$PY"
fi
