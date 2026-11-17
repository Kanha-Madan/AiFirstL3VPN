#!/usr/bin/env bash
# CT: validate + commit (no-networking) + idempotency check for sample instances.
# A second commit dry-run must produce an empty diff — proves the service mapping
# is idempotent.
set -euo pipefail

PACKAGES_DIR="${PACKAGES_DIR:-packages}"
NAME="${NSO_CONTAINER_NAME:-nso-ci}"
RUNTIME="${CONTAINER_RUNTIME:-docker}"
mkdir -p reports

# Detect runtime user (mirrors nso_container.sh / setup_packages.sh).
if ${RUNTIME} exec -u 0 "${NAME}" id nso >/dev/null 2>&1; then
  NSO_USER="nso"
else
  NSO_USER="root"
fi

# NSO CLI admin identity (not the container OS user above) — override via env.
NSO_ADMIN_USER="${NSO_ADMIN_USER:-admin}"

shopt -s nullglob
fail=0
found=0

for inst in "${PACKAGES_DIR}"/*/test/instances/*.xml; do
  found=1
  pkg=$(basename "$(dirname "$(dirname "$(dirname "${inst}")")")")
  name="$(basename "${inst}" .xml)"
  echo "---- commit-check ${pkg}/${name} ----"

  # Stream XML into container (/tmp) — safe to repeat even if dryrun already did it.
  tar -C "$(dirname "${inst}")" -cf - "$(basename "${inst}")" \
    | ${RUNTIME} exec -i -u "${NSO_USER}" "${NAME}" tar -C /tmp -xf - || true

  # Commit (no-networking: applies config to CDB without pushing to devices).
  # Commands piped via stdin — ncs_cli positional arg is a FILE PATH.
  printf 'config\nload merge /tmp/%s.xml\nvalidate\ncommit no-networking\nend\n' "${name}" \
    | ${RUNTIME} exec -i -u "${NSO_USER}" "${NAME}" ncs_cli -u "${NSO_ADMIN_USER}" -C \
    | tee "reports/commit-${pkg}-${name}.log" || fail=1

  # Idempotency: a second dry-run must produce no diff.
  diff_out=$(printf 'config\nload merge /tmp/%s.xml\ncommit dry-run\nabort\n' "${name}" \
    | ${RUNTIME} exec -i -u "${NSO_USER}" "${NAME}" ncs_cli -u "${NSO_ADMIN_USER}" -C 2>&1 || true)
  echo "${diff_out}" | tee "reports/idempotency-${pkg}-${name}.log"
  if echo "${diff_out}" | grep -qE '^\+|^\-|^cli \{'; then
    echo "==> commit_check: idempotency FAILED for ${pkg}/${name}"
    fail=1
  fi
done

if [[ ${found} -eq 0 ]]; then
  echo "==> commit_check: no sample instances — SKIPPING"
fi

# Surface any ncserr.log errors (log dir = /log per nso_container.sh setup).
# The main log file is ncserr.log; ignore rotated side-files (.idx, .siz, .1, …).
${RUNTIME} exec -u "${NSO_USER}" "${NAME}" sh -lc \
  'cat /log/ncserr.log 2>/dev/null || true' \
  | tee reports/ncserr.log
if [[ -s reports/ncserr.log ]]; then
  echo "==> commit_check: ncserr.log non-empty — FAILING"
  fail=1
fi

exit "${fail}"
