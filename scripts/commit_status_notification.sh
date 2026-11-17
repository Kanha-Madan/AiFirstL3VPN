#!/usr/bin/env bash
# CD: post commit status / send Webex notification.
# Usage: notify.sh <success|failure>  [message]
set -euo pipefail

STATUS="${1:-success}"
MESSAGE="${2:-NSO pipeline ${STATUS}}"

# Check if curl is available for API calls
if ! command -v curl >/dev/null 2>&1; then
  echo "==> notify: curl not available — skipping notifications"
  exit 0
fi

if [[ -n "${WEBEX_TOKEN:-}" && -n "${WEBEX_ROOM_ID:-}" ]]; then
  echo "==> notify: Webex room=${WEBEX_ROOM_ID} status=${STATUS}"
  curl -sS -X POST https://webexapis.com/v1/messages \
    -H "Authorization: Bearer ${WEBEX_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "{\"roomId\":\"${WEBEX_ROOM_ID}\",\"markdown\":\"**NSO pipeline ${STATUS}** — ${MESSAGE}\"}" \
    >/dev/null
else
  echo "==> notify: WEBEX_TOKEN/WEBEX_ROOM_ID not set — skipping Webex"
fi

# GitHub commit status (best-effort)
if [[ -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GIT_COMMIT:-}" ]]; then
  state=$([[ "${STATUS}" == success ]] && echo success || echo failure)
  curl -sS -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/statuses/${GIT_COMMIT}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -d "{\"state\":\"${state}\",\"context\":\"nso-cicd\",\"description\":\"${MESSAGE}\"}" >/dev/null
fi
