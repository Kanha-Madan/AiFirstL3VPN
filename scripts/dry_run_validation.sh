#!/usr/bin/env bash
# CT: dry-run any sample service instances under packages/*/test/instances/*.xml.
# Streams each XML into the container, loads it into candidate config, runs
# "commit dry-run outformat native", then aborts — no CDB state is left behind.
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
  echo "---- dry-run ${pkg}/${name} ----"

  # Stream instance XML into /tmp inside the container.
  tar -C "$(dirname "${inst}")" -cf - "$(basename "${inst}")" \
    | ${RUNTIME} exec -i -u "${NSO_USER}" "${NAME}" tar -C /tmp -xf - \
    || { echo "  failed to copy ${inst} into container"; fail=1; continue; }

  # Pipe CLI commands via stdin.
  # IMPORTANT: ncs_cli -C/-J positional arg is a FILE PATH not a command string.
  #            Commands must come from stdin; pass -i to exec to wire stdin through.
  printf 'config\nload merge /tmp/%s.xml\ncommit dry-run outformat native\nabort\n' "${name}" \
    | ${RUNTIME} exec -i -u "${NSO_USER}" "${NAME}" ncs_cli -u "${NSO_ADMIN_USER}" -C \
    | tee "reports/dryrun-${pkg}-${name}.log" \
    || { echo "  dry-run failed for ${pkg}/${name}"; fail=1; }
done

if [[ ${found} -eq 0 ]]; then
  echo "==> dryrun: no sample instances under packages/*/test/instances/ — SKIPPING"
fi
exit "${fail}"
