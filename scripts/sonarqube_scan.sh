#!/usr/bin/env bash
# CI: SonarQube scan. Fails fast if SONAR_HOST_URL/SONAR_TOKEN are not set.
set -euo pipefail

REPORT_DIR="${REPORT_DIR:-reports}"
mkdir -p "${REPORT_DIR}"

if [[ -z "${SONAR_HOST_URL:-}" ]]; then
  echo "==> sonar: SONAR_HOST_URL is not set — FAILING"
  echo "failed" > "${REPORT_DIR}/sonar.status"
  exit 1
fi

if [[ -z "${SONAR_TOKEN:-}" ]]; then
  echo "==> sonar: SONAR_TOKEN is not set — FAILING"
  echo "failed" > "${REPORT_DIR}/sonar.status"
  exit 1
fi

PROJECT_KEY="${SONAR_PROJECT_KEY:-$(basename "$(pwd)")}"
PROJECT_NAME="${SONAR_PROJECT_NAME:-${PROJECT_KEY}}"
SONAR_EXCLUSIONS="${SONAR_EXCLUSIONS:-**/load-dir/**,**/*.fxs,**/*.tar.gz,**/private-jar/**,**/shared-jar/**,**/*.java}"
echo "==> sonar: scanning project=${PROJECT_KEY} host=${SONAR_HOST_URL}"

if command -v sonar-scanner >/dev/null 2>&1; then
  sonar-scanner \
    -Dsonar.host.url="${SONAR_HOST_URL}" \
    -Dsonar.token="${SONAR_TOKEN}" \
    -Dsonar.projectKey="${PROJECT_KEY}" \
    -Dsonar.projectName="${PROJECT_NAME}" \
    -Dsonar.sources=packages \
    -Dsonar.exclusions="${SONAR_EXCLUSIONS}" \
    -Dsonar.qualitygate.wait=true \
    -Dsonar.qualitygate.timeout=300
elif command -v docker >/dev/null 2>&1; then
  SONAR_SCANNER_IMAGE="${SONAR_SCANNER_IMAGE:-sonarsource/sonar-scanner-cli:latest}"
  echo "==> sonar: sonar-scanner not found locally; using container image ${SONAR_SCANNER_IMAGE}"
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e SONAR_HOST_URL \
    -e SONAR_TOKEN \
    -v "$(pwd):/usr/src" \
    -w /usr/src \
    "${SONAR_SCANNER_IMAGE}" \
    -Dsonar.host.url="${SONAR_HOST_URL}" \
    -Dsonar.token="${SONAR_TOKEN}" \
    -Dsonar.projectKey="${PROJECT_KEY}" \
    -Dsonar.projectName="${PROJECT_NAME}" \
    -Dsonar.sources=packages \
    -Dsonar.exclusions="${SONAR_EXCLUSIONS}" \
    -Dsonar.qualitygate.wait=true \
    -Dsonar.qualitygate.timeout=300
else
  echo "==> sonar: neither sonar-scanner nor docker is available — FAILING"
  echo "failed" > "${REPORT_DIR}/sonar.status"
  exit 1
fi

echo "ok" > "${REPORT_DIR}/sonar.status"
echo "==> sonar: quality gate passed"
