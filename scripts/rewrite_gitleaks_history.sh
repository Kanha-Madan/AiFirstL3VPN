#!/usr/bin/env bash
# Rewrite git history to remove hardcoded NSO default credentials (admin:admin)
# from documentation and Docker examples flagged by Gitleaks (curl-auth-user).
#
# WARNING: Rewrites ALL branches/tags. Coordinate with the team, then force-push:
#   git push --force-with-lease --all
#   git push --force-with-lease --tags
#
# Usage (from repo root):
#   bash scripts/rewrite_gitleaks_history.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPLACEMENTS="${ROOT_DIR}/.gitleaks-replacements.txt"

if [[ ! -f "${REPLACEMENTS}" ]]; then
  echo "Missing ${REPLACEMENTS}" >&2
  exit 1
fi

if ! python3 -m git_filter_repo --version >/dev/null 2>&1; then
  echo "Install git-filter-repo: python3 -m pip install --user git-filter-repo" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree must be clean before rewriting history. Commit or stash changes first." >&2
  git status --short
  exit 1
fi

python3 -m git_filter_repo \
  --replace-text "${REPLACEMENTS}" \
  --force

echo "History rewrite complete. Verify with:"
echo "  gitleaks git --config .gitleaks.toml --redact"
echo "Then force-push if clean."
