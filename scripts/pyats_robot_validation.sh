#!/usr/bin/env bash
# CT: run pyATS or Robot tests if the project ships them.
set -euo pipefail
mkdir -p reports
source scripts/cxta_env_contract.sh

RUN_MODE="${RUN_MODE:-full}"
ROBOT_MODE_ARGS=()
case "${RUN_MODE}" in
  full) ;;
  atp) ROBOT_MODE_ARGS=(--include ATP) ;;
  smoke) ROBOT_MODE_ARGS=(--include smoke) ;;
  *)
    echo "==> CXTA: invalid RUN_MODE '${RUN_MODE}' (expected full, atp, or smoke)" >&2
    exit 2
    ;;
esac

# Read CXTA version/image from nso-dependencies.yaml. Current format nests
# these under each project block (e.g. "example-l3vpn 0.1:"), not under a
# top-level "cxta:" key, so pull the first "cxta-version:"/"cxta-image:"
# match regardless of which project block it lives in.
NSO_DEPENDENCIES_FILE="${NSO_DEPENDENCIES_FILE:-nso-dependencies.yaml}"
# `|| true` guards each substitution: under `set -e -o pipefail`, a no-match
# grep (exit 1) would otherwise kill the script here instead of falling
# through to the ${VAR:-default} below.
CXTA_VERSION=$(grep -m1 -E "^[[:space:]]+cxta-version:" "${NSO_DEPENDENCIES_FILE}" 2>/dev/null | awk '{print $2}') || true
CXTA_IMAGE=$(grep -m1 -E "^[[:space:]]+cxta-image:" "${NSO_DEPENDENCIES_FILE}" 2>/dev/null | awk '{print $2}') || true
CXTA_VERSION="${CXTA_VERSION:-26.8}"
CXTA_IMAGE="${CXTA_IMAGE:-dockerhub.cisco.com/cxta-docker/cxta}"

# Self-contained CXTA<->NSO connectivity + robot execution. Does not depend on
# any test-folder-owned runner script existing — scripts/ must be able to
# establish this connection on its own regardless of the tests/ layout.
# mount_dir: host dir bind-mounted read-only as /workspace inside the CXTA
#            container. target_path: path under /workspace passed to `robot`.
run_cxta_suite() {
  local mount_dir="$1" target_path="$2"
  local runtime="${CONTAINER_RUNTIME:-docker}"
  # Unique per job (NSO_CONTAINER_NAME = nso-ci-<job>-<build>), so another
  # branch's build with the same build number never shares this network.
  local run_id="${NSO_CONTAINER_NAME:-nso-ci}"; run_id="${run_id#nso-ci}"; run_id="${run_id#-}"
  local network_name="nso-test-network-${run_id:-local}"
  local CI_OWNER_LABEL="ci.owner=aifirst-nso"  # marks everything we create; scripts/cleanup.sh sweeps by it
  local nso_host="${NSO_HOST:-${NSO_CONTAINER_NAME:-nso-ci}}"
  local nso_port="${NSO_PORT:-8080}"
  local output_dir="reports/robot"
  local robot_filter=""
  [[ "${RUN_MODE}" == "atp" ]] && robot_filter="--include ATP"
  [[ "${RUN_MODE}" == "smoke" ]] && robot_filter="--include smoke"

  if ! command -v "${runtime}" >/dev/null 2>&1; then
    echo "==> CXTA: ${runtime} not available — FAILING"
    return 1
  fi

  mkdir -p "${output_dir}"
  echo "==> CXTA: pulling ${CXTA_IMAGE}:${CXTA_VERSION}"
  "${runtime}" pull "${CXTA_IMAGE}:${CXTA_VERSION}" 2>/dev/null || "${runtime}" pull "${CXTA_IMAGE}" || return 1

  if ! "${runtime}" ps --format '{{.Names}}' | grep -qx "${nso_host}"; then
    echo "==> CXTA: NSO container '${nso_host}' is not running — FAILING"
    return 1
  fi

  # Join the NSO container's network namespace. Inside CXTA, 'localhost' is then
  # NSO itself, so a generated library that falls back to a testbed
  # 'http://localhost:8080/restconf' still reaches NSO. NSO_HOST is exported as
  # 'localhost' for the same reason (env-aware libraries resolve to the same place).
  local cxta_network="container:${nso_host}"
  local cxta_nso_host="localhost"
  if [[ "${CXTA_NETWORK_MODE:-shared}" == "bridge" ]]; then
    "${runtime}" network inspect "${network_name}" >/dev/null 2>&1 || \
      "${runtime}" network create --label "${CI_OWNER_LABEL}" "${network_name}" || true
    "${runtime}" network connect "${network_name}" "${nso_host}" 2>/dev/null || true
    cxta_network="${network_name}"
    cxta_nso_host="${nso_host}"
  fi
  echo "==> CXTA: network=${cxta_network} NSO_HOST=${cxta_nso_host}:${nso_port}"

  # Endpoint vars are connection settings, not secrets. Export the values this
  # run already resolved before scanning testbed *_env names. A testbed may
  # declare url_env/host_env/port_env; randomizing those overrides the real
  # endpoint and makes requests fail with InvalidSchema.
  export NSO_HOST="${cxta_nso_host}"
  export NSO_PORT="${nso_port}"
  if [[ -z "${NSO_RESTCONF_URL:-}" ]]; then
    export NSO_RESTCONF_URL="http://${cxta_nso_host}:${nso_port}/restconf"
  fi

  # Classify by the YAML field, never by a token-looking variable name.
  # Endpoint and identity fields are not secrets. Only explicit secret fields
  # for this disposable test environment may receive a generated value.
  local env_args=() key var class raw
  while read -r key var; do
    [[ -z "${key:-}" || -z "${var:-}" ]] && continue
    class="$(cxta_env_class "${key}")"
    case "${class}:${key}" in
      endpoint:url_env) export "${var}=http://${cxta_nso_host}:${nso_port}/restconf" ;;
      endpoint:host_env) export "${var}=${cxta_nso_host}" ;;
      endpoint:port_env) export "${var}=${nso_port}" ;;
      identity:*)
        if [[ -z "${!var:-}" ]]; then
          echo "==> CXTA: ${var} unset — testbed device name applies"
          continue
        fi
        ;;
      credential:*)
        if [[ -z "${!var:-}" ]]; then
          echo "==> CXTA: required credential variable ${var} is unset — FAILING"
          return 1
        fi
        ;;
      disposable-secret:*)
        if [[ -z "${!var:-}" ]]; then
          raw="$(dd if=/dev/urandom bs=512 count=1 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9')"
          export "${var}=${raw:0:24}"
          echo "==> CXTA: ${var} generated once for disposable netsim"
        fi
        ;;
      passthrough:*)
        if [[ -z "${!var:-}" ]]; then
          echo "==> CXTA: ${var} unset — testbed/default context applies"
          continue
        fi
        ;;
    esac
    env_args+=(-e "${var}")
  done < <(cxta_env_pairs "${mount_dir}"/environments/*.yaml)

  # RESTCONF credentials were provisioned once by setup_nso_container.sh from
  # the pipeline's NSO_RESTCONF_PASSWORD. Never default or regenerate them here
  # (a new value would no longer match the provisioned account); a missing
  # password is a FAIL. Forwarded by NAME only (`-e VAR`), like the secrets
  # above, so no value appears in process arguments.
  if [[ -z "${NSO_RESTCONF_PASSWORD:-}" ]]; then
    echo "==> CXTA: NSO_RESTCONF_PASSWORD is not set — FAILING"
    return 1
  fi
  export NSO_RESTCONF_USER="${NSO_RESTCONF_USER:-admin}" NSO_RESTCONF_PASSWORD
  echo "==> CXTA: checking RESTCONF authentication"
  local auth_code
  auth_code="$("${runtime}" exec -e NSO_RESTCONF_USER -e NSO_RESTCONF_PASSWORD "${nso_host}" \
    python3 -c 'import os, urllib.request, urllib.error, base64
user = os.environ["NSO_RESTCONF_USER"]
password = os.environ["NSO_RESTCONF_PASSWORD"]
req = urllib.request.Request("http://127.0.0.1:8080/restconf/data/tailf-ncs:packages")
token = base64.b64encode(("%s:%s" % (user, password)).encode()).decode()
req.add_header("Authorization", "Basic " + token)
req.add_header("Accept", "application/yang-data+json")
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        print(resp.status)
except urllib.error.HTTPError as exc:
    print(exc.code)
')"
  auth_code="${auth_code//$'\r'/}"
  auth_code="${auth_code//$'\n'/}"
  if [[ "${auth_code}" != "200" ]]; then
    echo "==> CXTA: RESTCONF authentication failed (HTTP ${auth_code}) — FAILING" >&2
    return 1
  fi
  # Named (cxta-<nso container>) so scripts/cleanup.sh can find and remove it if
  # the build is aborted mid-run — --rm alone only helps when the run finishes.
  # Drop any same-named leftover first so a stale one can't block this run.
  local cxta_name="cxta-${nso_host}"
  "${runtime}" rm -f -v "${cxta_name}" >/dev/null 2>&1 || true
  "${runtime}" run --rm \
    --label "${CI_OWNER_LABEL}" \
    --name "${cxta_name}" \
    --network "${cxta_network}" \
    ${env_args[@]+"${env_args[@]}"} \
    -e NSO_HOST="${cxta_nso_host}" -e NSO_PORT="${nso_port}" \
    -e NSO_RESTCONF_URL="${NSO_RESTCONF_URL}" \
    -e NSO_RESTCONF_USER -e NSO_RESTCONF_PASSWORD \
    -v "$(pwd)/${mount_dir}:/workspace:ro" \
    -v "$(pwd)/${output_dir}:/output" \
    "${CXTA_IMAGE}:${CXTA_VERSION}" \
    bash -lc "robot ${robot_filter} --outputdir /output /workspace/${target_path}"
}

if [[ -d test/pyats || -d tests/pyats ]]; then
  dir=$([[ -d test/pyats ]] && echo test/pyats || echo tests/pyats)
  echo "==> pyats: running jobs under ${dir}"
  if ! command -v pyats >/dev/null 2>&1; then
    echo "==> pyats: pyATS not installed — FAILING"
    exit 1
  fi
  pyats run job "${dir}/job.py" --archive-dir reports/pyats || exit 1

elif compgen -G "tests/tests/*/scripts/*.robot" >/dev/null; then
  # Current repo layout: tests/tests/<suite>/scripts/*.robot. CXTA<->NSO
  # connectivity is established by scripts/ itself (run_cxta_suite) — no
  # dependency on any test-folder-owned runner file.
  # NSO_CONTAINER_NAME must match setup_nso_container.sh's own default so a
  # local run (no Jenkins env exported) still finds the right container name.
  export NSO_CONTAINER_NAME="${NSO_CONTAINER_NAME:-nso-ci}"
  echo "==> CXTA: connecting to NSO (NSO_CONTAINER_NAME=${NSO_CONTAINER_NAME})"
  run_cxta_suite "tests" "tests" || exit 1

elif [[ -d tests/robot_files || -d test/robot ]]; then
  # Determine which directory structure to use
  if [[ -d tests/robot_files ]]; then
    dir="tests/robot_files"
    echo "==> CXTA: running robot tests under ${dir}"
  else
    dir="test/robot"
    echo "==> robot: running suites under ${dir}"
  fi

  # Use CXTA container if available (for tests/robot_files structure)
  if [[ -d tests/robot_files ]] && command -v "${CONTAINER_RUNTIME:-docker}" >/dev/null 2>&1; then
    export NSO_CONTAINER_NAME="${NSO_CONTAINER_NAME:-nso-ci}"
    run_cxta_suite "tests" "robot_files" || exit 1
    echo "==> CXTA: Tests completed, reports in reports/robot/"
  elif command -v robot >/dev/null 2>&1; then
    # Fallback to local robot installation
    echo "==> robot: Using local Robot Framework installation"
    robot "${ROBOT_MODE_ARGS[@]}" --outputdir reports/robot "${dir}" || exit 1
  else
    echo "==> robot: Robot Framework/CXTA not available — FAILING"
    exit 1
  fi

elif [[ -d qa/03_cxta_automation/tests ]] && [[ -n "$(find qa/03_cxta_automation/tests -name '*.robot' -print -quit 2>/dev/null)" ]]; then
  # NOTE: do not use `find ... | grep -q .` here. Under `set -o pipefail`,
  # grep -q exits on the first match and find (when its output exceeds one
  # stdio buffer, ~4 KB) then dies with SIGPIPE (rc 141), making the whole
  # pipeline "false" and silently skipping CXTA. `-print -quit` avoids the pipe.
  # QA-track repo layout (see .cursor/skills/af-qa-* / qa/README): robot
  # suites live under qa/03_cxta_automation/tests/<Track>/... with shared
  # keywords/libraries/resources one level up. Paths inside the .robot files
  # are all relative (../resources, ../../../../../../keywords, etc.), so
  # this works whether mounted into the CXTA container or run in place.
  runtime="${CONTAINER_RUNTIME:-docker}"
  export NSO_CONTAINER_NAME="${NSO_CONTAINER_NAME:-nso-ci}"
  nso_host="${NSO_HOST:-${NSO_CONTAINER_NAME}}"

  if command -v "${runtime}" >/dev/null 2>&1 && "${runtime}" ps --format '{{.Names}}' 2>/dev/null | grep -qx "${nso_host}"; then
    echo "==> CXTA: connecting to NSO (NSO_CONTAINER_NAME=${NSO_CONTAINER_NAME})"
    run_cxta_suite "qa/03_cxta_automation" "tests" || exit 1
    echo "==> CXTA: Tests completed, reports in reports/robot/"
  elif command -v robot >/dev/null 2>&1; then
    # No CXTA/NSO container reachable (e.g. NSO installed natively rather than
    # in Docker) — fall back to whatever Robot Framework is on PATH and let
    # keywords hit NSO_RESTCONF_URL/localhost directly via the testbed yaml.
    echo "==> robot: '${nso_host}' container not running — using local Robot Framework installation"
    mkdir -p reports/robot
    robot "${ROBOT_MODE_ARGS[@]}" --outputdir reports/robot qa/03_cxta_automation/tests || exit 1
  else
    echo "==> robot: Robot Framework/CXTA not available — FAILING"
    exit 1
  fi
else
  echo "==> pyats: no test/pyats, tests CXTA suite, tests/robot_files, or qa/03_cxta_automation/tests directory — SKIPPING"
  # Diagnostics so a wrongly-skipped run is explainable from the Jenkins log.
  echo "==> pyats: diag: pwd=$(pwd) qa-tests-dir-exists=$([[ -d qa/03_cxta_automation/tests ]] && echo yes || echo no) robot-file-count=$(find qa/03_cxta_automation/tests -name '*.robot' 2>/dev/null | wc -l | tr -d ' ')"
fi
