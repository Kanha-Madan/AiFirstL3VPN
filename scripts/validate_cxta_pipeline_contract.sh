#!/usr/bin/env bash
# Static contract check shared by the QA Builder and Jenkins.
set -euo pipefail

fail() {
  echo "ERROR: CXTA pipeline contract: $*" >&2
  exit 1
}

testbed_glob="${TESTBED_GLOB:-qa/03_cxta_automation/environments/*.yaml}"

bash -n scripts/pyats_robot_validation.sh
bash -n scripts/netsim_simulation.sh
bash -n scripts/setup_nso_container.sh
bash -n scripts/cxta_env_contract.sh

if grep -nE '^[[:space:]]*(username|password):[[:space:]]*[^$[:space:]][^#]*$' \
    ${testbed_glob} 2>/dev/null; then
  fail "testbed contains a literal username/password; use *_env references"
fi

if grep -nE '^[[:space:]]*user_env:' ${testbed_glob} 2>/dev/null; then
  fail "testbed uses user_env; NsoLib requires username_env"
fi
grep -qE '^[[:space:]]*username_env:[[:space:]]*NSO_RESTCONF_USER[[:space:]]*$' \
  ${testbed_glob} 2>/dev/null ||
  fail "testbed does not bind NSO username_env to NSO_RESTCONF_USER"
grep -qE '^[[:space:]]*password_env:[[:space:]]*NSO_RESTCONF_PASSWORD[[:space:]]*$' \
  ${testbed_glob} 2>/dev/null ||
  fail "testbed does not bind NSO password_env to NSO_RESTCONF_PASSWORD"

if grep -nE "NSO_RESTCONF_PASSWORD[[:space:]]*=[[:space:]]*['\"][A-Za-z0-9]|NSO_RESTCONF_PASSWORD[[:space:]]*:[[:space:]]*['\"]?[A-Za-z0-9]" \
    Jenkinsfile .github/workflows/*.y*ml 2>/dev/null; then
  fail "NSO_RESTCONF_PASSWORD is hardcoded instead of generated/injected"
fi

grep -q 'NSO_RESTCONF_URL="http://${cxta_nso_host}:${nso_port}/restconf"' \
  scripts/pyats_robot_validation.sh ||
  fail "CXTA runner does not derive NSO_RESTCONF_URL"
grep -q -- '-e NSO_RESTCONF_USER -e NSO_RESTCONF_PASSWORD' \
  scripts/pyats_robot_validation.sh ||
  fail "CXTA runner does not forward RESTCONF credentials by name"
grep -q -- '-e NSO_RESTCONF_USER -e NSO_RESTCONF_PASSWORD' \
  scripts/setup_nso_container.sh ||
  fail "NSO setup does not consume the same RESTCONF credentials"
grep -q 'NSO_RESTCONF_PASSWORD must be generated or injected by CI' \
  scripts/setup_nso_container.sh ||
  fail "NSO setup does not require a runtime password"

# Regression fixture: classification follows YAML field semantics, so endpoint
# and identity variables are never randomized even when their names look secret.
source scripts/cxta_env_contract.sh
env_fixture="$(
  printf '%s\n' \
    'url_env NSO_ENDPOINT_TOKEN' \
    'host_env LAB_HOST_SECRET' \
    'port_env NSO_PORT' \
    'name_env DEVICE_PASSWORD' \
    'bgp_password_env BGP_PASSWORD' |
    cxta_env_plan
)"
grep -q 'endpoint|url_env|NSO_ENDPOINT_TOKEN|derived-url' <<<"${env_fixture}" ||
  fail "url_env is not classified as a derived endpoint"
grep -q 'endpoint|host_env|LAB_HOST_SECRET|derived-host' <<<"${env_fixture}" ||
  fail "host_env is not classified as a derived endpoint"
grep -q 'identity|name_env|DEVICE_PASSWORD|testbed-default' <<<"${env_fixture}" ||
  fail "name_env is not classified as testbed identity"
grep -q 'disposable-secret|bgp_password_env|BGP_PASSWORD|random-if-unset' <<<"${env_fixture}" ||
  fail "disposable test secret is not classified correctly"

grep -q 'qa/03_cxta_automation/tests' scripts/pyats_robot_validation.sh ||
  fail "CXTA runner does not discover canonical Gate 3 suites"

set +e
plan="$(
  TESTBED_GLOB="${testbed_glob}" NETSIM_DRY_RUN=true \
    bash scripts/netsim_simulation.sh 2>&1
)"
plan_rc=$?
set -e
printf '%s\n' "${plan}"
if grep -q 'no testbed devices found' <<<"${plan}"; then
  fail "no generated testbed device was recognized; Jenkins would use the fallback"
fi
grep -q 'devices from testbeds' <<<"${plan}" ||
  fail "netsim did not read generated testbed devices"

packages_present=no
if [[ -d packages ]] && find packages -mindepth 1 -maxdepth 1 -type d -print -quit | grep -q .; then
  packages_present=yes
fi
if [[ "${packages_present}" == "no" ]]; then
  # packages/ is downloaded later. find exits before the NED error when the dir is absent.
  echo "==> CXTA pipeline contract: device schema recognized; NED packages are not downloaded yet"
elif [[ "${plan_rc}" -ne 0 ]]; then
  fail "netsim cannot derive devices/NEDs from generated testbeds"
else
  grep -q 'ned=' <<<"${plan}" ||
    fail "generated testbed did not resolve any NED package"
fi

echo "==> CXTA pipeline contract: PASS"
