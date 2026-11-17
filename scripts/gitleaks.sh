#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# gitleaks.sh — Secret scanning via the official GitLeaks Docker image.
#
# Default mode scans the checked-out workspace only (no git history). This
# matches CI intent: block secrets in the code being built, not legacy commits
# in shallow Jenkins clones.
#
# Set GITLEAKS_MODE=git to scan git history (uses GITLEAKS_LOG_OPTS).
#
# Environment variables (all optional with safe defaults):
#   GITLEAKS_IMAGE     Docker image (default: ghcr.io/gitleaks/gitleaks:latest)
#   GITLEAKS_MODE      detect (default) or git
#   GITLEAKS_LOG_OPTS  git log range when mode=git (default: origin/main..HEAD)
#   REPORT_PATH        Output JSON path (default: gitleaks-report.json)
#   WORKSPACE          Repository root (default: $PWD)
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

GITLEAKS_IMAGE="${GITLEAKS_IMAGE:-ghcr.io/gitleaks/gitleaks:latest}"
GITLEAKS_MODE="${GITLEAKS_MODE:-detect}"
REPORT_PATH="${REPORT_PATH:-gitleaks-report.json}"
REPO_ROOT="${WORKSPACE:-$(git -C "${SCRIPT_DIR}/.." rev-parse --show-toplevel 2>/dev/null || printf '%s' "$ROOT_DIR") }"
REPO_ROOT="${REPO_ROOT% }"
DEFAULT_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '%s' 'master')"
if git -C "${REPO_ROOT}" rev-parse --verify origin/master >/dev/null 2>&1; then
  DEFAULT_BRANCH="master"
elif git -C "${REPO_ROOT}" rev-parse --verify origin/main >/dev/null 2>&1; then
  DEFAULT_BRANCH="main"
fi
GITLEAKS_LOG_OPTS="${GITLEAKS_LOG_OPTS:-origin/${DEFAULT_BRANCH}..HEAD}"
GITLEAKS_CONFIG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gitleaks-config.XXXXXX")"
chmod 755 "${GITLEAKS_CONFIG_DIR}"
GITLEAKS_CONFIG="${GITLEAKS_CONFIG_DIR}/gitleaks.toml"
GITLEAKS_CONFIG_MOUNT="/config/gitleaks.toml"
GITLEAKS_REPO_CONFIG="${REPO_ROOT}/.gitleaks.toml"
trap 'rm -rf "${GITLEAKS_CONFIG_DIR}"' EXIT

ensure_gitleaks_config() {
  if [[ -f "${GITLEAKS_REPO_CONFIG}" ]]; then
    cp "${GITLEAKS_REPO_CONFIG}" "${GITLEAKS_CONFIG}"
    echo "INFO: Copied repo GitLeaks config to ${GITLEAKS_CONFIG}"
    return 0
  fi

  cat > "${GITLEAKS_CONFIG}" <<'EOF'
title = "Default repository Gitleaks config"

[extend]
useDefault = true

[[allowlists]]
description = "Placeholder/example addresses and sample credentials"
regexTarget = "line"
regexes = [
  '''192\.0\.2\.\d+''',
  '''198\.51\.100\.\d+''',
  '''203\.0\.113\.\d+''',
  '''2001:db8:''',
  '''netsim''',
  '''example\.com''',
]
EOF

  echo "INFO: Created default GitLeaks config at ${GITLEAKS_CONFIG}"
}

log_step "GitLeaks secret scanning (mode=${GITLEAKS_MODE})"

if [[ -z "${REPO_ROOT}" || ! -d "${REPO_ROOT}" ]]; then
  echo "ERROR: repository root is not resolved. WORKSPACE='${WORKSPACE:-}' REPO_ROOT='${REPO_ROOT:-}'" >&2
  exit 1
fi

if [[ ! -f "${GITLEAKS_REPO_CONFIG}" ]]; then
  echo "INFO: repo config missing at ${GITLEAKS_REPO_CONFIG}; creating default config before Docker run" >&2
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker is not available on this agent. Cannot run GitLeaks scan." >&2
  exit 1
fi

ensure_gitleaks_config

echo "INFO: active gitleaks config = ${GITLEAKS_CONFIG}"
ls -la "${GITLEAKS_CONFIG_DIR}" | sed -n '1,20p'
ls -l "${GITLEAKS_CONFIG}"

if [[ ! -f "${GITLEAKS_CONFIG}" ]]; then
  echo "ERROR: GitLeaks config is missing from ${GITLEAKS_CONFIG} before Docker run." >&2
  exit 1
fi

docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
echo "Docker version: ${docker_version}"

DOCKER_ARGS=(
  "--rm"
  "--user" "$(id -u):$(id -g)"
  "-v" "${REPO_ROOT}:/repo"
  "-v" "${GITLEAKS_CONFIG}:${GITLEAKS_CONFIG_MOUNT}:ro"
  "-w" "/repo"
)

if [[ "${GITLEAKS_MODE}" == "git" ]]; then
  if ! git -C "${REPO_ROOT}" rev-parse --verify "origin/${DEFAULT_BRANCH}" >/dev/null 2>&1; then
    echo "Fetching origin/${DEFAULT_BRANCH} to establish diff base..."
    git -C "${REPO_ROOT}" fetch --no-tags "origin" "${DEFAULT_BRANCH}:refs/remotes/origin/${DEFAULT_BRANCH}" || {
      echo "WARNING: Could not fetch origin/${DEFAULT_BRANCH}; scanning current commit only (HEAD)." >&2
      GITLEAKS_LOG_OPTS="HEAD"
    }
  fi

  GITLEAKS_ARGS=(
    "git"
    "--config" "${GITLEAKS_CONFIG_MOUNT}"
    "--report-format" "json"
    "--report-path" "${REPORT_PATH}"
  )

  if [[ -f "${REPO_ROOT}/.gitleaks.baseline.json" ]]; then
    GITLEAKS_ARGS+=("--baseline-path" "/repo/.gitleaks.baseline.json")
  fi

  if [[ -n "${GITLEAKS_LOG_OPTS}" ]]; then
    GITLEAKS_ARGS+=("--log-opts=${GITLEAKS_LOG_OPTS}")
  fi
else
  GITLEAKS_ARGS=(
    "detect"
    "--source" "/repo"
    "--config" "${GITLEAKS_CONFIG_MOUNT}"
    "--no-git"
    "--report-format" "json"
    "--report-path" "${REPORT_PATH}"
  )
fi

scan_exit=0
echo "Running: docker run ${DOCKER_ARGS[*]} ${GITLEAKS_IMAGE} ${GITLEAKS_ARGS[*]}"
docker run "${DOCKER_ARGS[@]}" "${GITLEAKS_IMAGE}" "${GITLEAKS_ARGS[@]}" || scan_exit=$?

ensure_artifact_dir
if [[ -f "${REPO_ROOT}/${REPORT_PATH}" ]]; then
  cp "${REPO_ROOT}/${REPORT_PATH}" "${ARTIFACT_DIR}/${REPORT_PATH}"
  echo "Report saved to ${ARTIFACT_DIR}/${REPORT_PATH}"
fi

if [[ "${scan_exit}" -ne 0 ]]; then
  echo "ERROR: GitLeaks detected secrets or the scan failed (exit code: ${scan_exit})." >&2
  exit "${scan_exit}"
fi

log_step "GitLeaks scan complete — no secrets detected."