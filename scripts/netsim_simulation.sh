#!/usr/bin/env bash
# CT: bring up netsim devices for the devices declared in the QA testbeds,
#     then load them into NSO, fetch SSH host keys, and sync-from.
#
# Device inventory is derived from the `testbed.devices` block of every YAML
# file in the QA environments dir, so netsim always creates exactly the device
# names the generated tests use. Two shapes are accepted:
#   devices: { xr0: { ned: cisco-iosxr } }
#   devices: { <alias>: { name: xr75-0, ned_id: cisco-iosxr-cli-7.75 } }
# `name` (when present) is the NSO device name; otherwise the YAML key is.
# `ned` and `ned_id` both name the NED package prefix.
# Any *.yaml there is scanned; a file without a `testbed.devices` block simply
# contributes nothing.
# Precedence:
#   1. NETSIM_DEVICES env  — space-separated "<name>:<ned-prefix>" pairs
#   2. testbed YAMLs       — ${TESTBED_GLOB}
#   3. fallback            — "pe0:cisco-iosxr-cli"
#
# Device names are used exactly as written — abc, xyz, pqrs, pe0, xr1 ... any
# letters/digits/_ . - . Each NED prefix in `ned:` is resolved to a package
# directory under packages/, so different devices may use different NEDs.
# Names shaped "<prefix><n>" whose indexes run 0..N-1 on one NED (xr0, xr1, xr2)
# are created together as one ncs-netsim network (create-network / add-to-network);
# every other name is created individually (create-device / add-device).
#
# NETSIM_DRY_RUN=true prints the resolved plan and exits before touching any
# container — use it to check what a testbed would create.
set -euo pipefail

PACKAGES_DIR="${PACKAGES_DIR:-packages}"
NAME="${NSO_CONTAINER_NAME:-nso-ci}"
RUNTIME="${CONTAINER_RUNTIME:-docker}"
TESTBED_GLOB="${TESTBED_GLOB:-qa/03_cxta_automation/environments/*.yaml}"
NETSIM_DRY_RUN="${NETSIM_DRY_RUN:-false}"

# Print "<device>:<ned>" for each entry under the top-level `testbed:` ->
# `devices:` block (block-style YAML; flow style `{a: b}` is not supported).
# Keys outside `testbed:` are ignored, so an unrelated *.yaml that happens to
# have its own `devices:` key is not mistaken for a testbed.
testbed_devices() {
  awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function unquote(s) { sub(/[[:space:]]+#.*/, "", s); gsub(/["\047]/, "", s); return s }
    FNR == 1 { in_tb = 0; in_dev = 0; dev = ""; devname = ""; key_ind = -1 }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      ind = indent($0)
      line = $0; sub(/^ */, "", line)
      if (ind == 0) { in_tb = (line ~ /^testbed:[[:space:]]*(#.*)?$/); in_dev = 0; next }
      if (!in_tb) next
      if (in_dev && ind <= dev_ind) { in_dev = 0 }
      if (line ~ /^devices:[[:space:]]*(#.*)?$/) { in_dev = 1; dev_ind = ind; dev = ""; devname = ""; key_ind = -1; next }
      if (!in_dev) next
      if (key_ind < 0) key_ind = ind
      if (ind == key_ind) { dev = line; sub(/:.*/, "", dev); devname = ""; next }
      # `name:` is the NSO device name. `name_env:` only names an override env var.
      if (dev != "" && line ~ /^name:/) {
        devname = unquote(line); sub(/^name:[[:space:]]*/, "", devname); next
      }
      if (dev != "" && line ~ /^ned(_id)?:/) {
        ned = unquote(line); sub(/^ned(_id)?:[[:space:]]*/, "", ned)
        print (devname != "" ? devname : dev) ":" ned
      }
    }
  ' "$@" 2>/dev/null
}

# Turn "<name>:<ned>" lines (stdin) into a creation plan, one line per action:
#   net <prefix> <ned> <count>   -> <prefix>0..<prefix>{count-1}, one ncs-netsim network
#   dev <name>   <ned> 1         -> a single device, created under its exact name
# A group becomes a `net` only when its names are "<prefix><n>" (no leading zero
# in n), all on one NED, and n runs contiguously from 0; anything else is `dev`.
# Invalid input (empty name/ned, illegal characters, one name on two NEDs) is
# reported on stderr with a non-zero exit and no plan.
plan_devices() {
  awk -F: '
    function fail(msg) { print "  ERROR: " msg > "/dev/stderr"; bad = 1 }
    NF == 0 { next }
    {
      name = $1; ned = $2
      if (name == "" || ned == "") { fail("entry \"" $0 "\" must be <device>:<ned>"); next }
      if (name !~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/) {
        fail("device name \"" name "\" may only contain letters, digits, _ . - and must start with a letter or digit"); next
      }
      if (name in ned_of) {
        if (ned_of[name] != ned) fail("device \"" name "\" is declared with two NEDs (" ned_of[name] " and " ned ")")
        next
      }
      ned_of[name] = ned; order[++n] = name
      if (match(name, /[0-9]+$/)) {
        p = substr(name, 1, RSTART - 1); i = substr(name, RSTART)
        if (p != "" && i ~ /^(0|[1-9][0-9]*)$/) {
          pfx[name] = p
          cnt[p]++
          if (!(p in max) || i + 0 > max[p]) max[p] = i + 0
          if (!(p in pned)) pned[p] = ned; else if (pned[p] != ned) mixed[p] = 1
        }
      }
    }
    END {
      if (bad) exit 1
      for (k = 1; k <= n; k++) {
        nm = order[k]; p = pfx[nm]
        if (p != "" && !mixed[p] && cnt[p] == max[p] + 1) {
          if (!(p in done)) { done[p] = 1; print "net", p, pned[p], cnt[p] }
        } else print "dev", nm, ned_of[nm], 1
      }
    }
  '
}

DEVICE_NED_PAIRS=()
if [[ -n "${NETSIM_DEVICES:-}" ]]; then
  read -r -a DEVICE_NED_PAIRS <<< "${NETSIM_DEVICES}"
  echo "==> netsim_up: devices from NETSIM_DEVICES: ${DEVICE_NED_PAIRS[*]}"
else
  # shellcheck disable=SC2206
  testbeds=( ${TESTBED_GLOB} )
  if [[ -e "${testbeds[0]:-}" ]]; then
    while IFS= read -r pair; do
      [[ -n "${pair}" ]] && DEVICE_NED_PAIRS+=("${pair}")
    done < <(testbed_devices "${testbeds[@]}" | awk -F: '!seen[$1]++')
  fi
  if [[ ${#DEVICE_NED_PAIRS[@]} -gt 0 ]]; then
    echo "==> netsim_up: devices from testbeds (${TESTBED_GLOB}): ${DEVICE_NED_PAIRS[*]}"
  else
    DEVICE_NED_PAIRS=("pe0:cisco-iosxr-cli")
    echo "==> netsim_up: no testbed devices found — fallback: ${DEVICE_NED_PAIRS[*]}"
  fi
fi

# Validate the names and turn them into a creation plan.
plan="$(printf '%s\n' "${DEVICE_NED_PAIRS[@]}" | plan_devices)" || exit 1

# Resolve each NED prefix to a package directory under PACKAGES_DIR (name
# includes the pinned version, e.g. "cisco-iosxr-cli" -> "cisco-iosxr-cli-7.61").
ACTIONS=()   # "<net|dev>|<prefix-or-name>|<ned-package>|<count>"
fail=0
while read -r kind target ned_match count; do
  ned_pkg="$(find "${PACKAGES_DIR}" -maxdepth 1 -type d -name "${ned_match}*" 2>/dev/null | sort | head -1)"
  ned_pkg="$(basename "${ned_pkg:-}")"
  if [[ -z "${ned_pkg}" ]]; then
    echo "  ERROR: no NED package matching '${ned_match}*' found under ${PACKAGES_DIR}/ (needed by ${target}) — run download_dependencies.sh first"
    fail=1; continue
  fi
  ACTIONS+=("${kind}|${target}|${ned_pkg}|${count}")
done <<< "${plan}"
[[ "${fail}" -ne 0 ]] && exit "${fail}"

if [[ "${NETSIM_DRY_RUN}" == "true" ]]; then
  echo "==> netsim_up: DRY RUN — would create:"
  for action in "${ACTIONS[@]}"; do
    IFS='|' read -r kind target ned_pkg count <<< "${action}"
    if [[ "${kind}" == "net" ]]; then
      for ((i = 0; i < count; i++)); do echo "      ${target}${i}  ned=${ned_pkg}  (network ${target})"; done
    else
      echo "      ${target}  ned=${ned_pkg}"
    fi
  done
  exit 0
fi

# Detect runtime user (mirrors nso_container.sh / setup_packages.sh).
if ${RUNTIME} exec -u 0 "${NAME}" id nso >/dev/null 2>&1; then
  NSO_USER="nso"
else
  NSO_USER="root"
fi

# NSO CLI admin identity (not the container OS user above) — override via env.
NSO_ADMIN_USER="${NSO_ADMIN_USER:-admin}"

# Credentials netsim devices themselves accept over SSH (ncs-netsim's own
# fixed default is admin/admin — override via env if devices were customized).
NETSIM_DEVICE_USER="${NETSIM_DEVICE_USER:-admin}"
NETSIM_DEVICE_PASSWORD="${NETSIM_DEVICE_PASSWORD:-admin}"

mkdir -p reports

for action in "${ACTIONS[@]}"; do
  IFS='|' read -r kind target ned_pkg count <<< "${action}"
  if [[ "${kind}" == "net" ]]; then
    # "<prefix>0..<prefix>N-1" in one go.
    sub_new="create-network"; sub_add="add-to-network"; sub_args="${count} ${target}"
    if [[ "${count}" -eq 1 ]]; then what="${target}0"; else what="${target}0..${target}$((count - 1))"; fi
  else
    # One device, exact name.
    sub_new="create-device"; sub_add="add-device"; sub_args="${target}"
    what="${target}"
  fi
  echo "---- netsim create: ${what} ned=${ned_pkg} ----"
  ${RUNTIME} exec -u "${NSO_USER}" "${NAME}" sh -lc "
    set -e
    cd /nso/run

    ned_path=/nso/run/packages/${ned_pkg}
    if [ ! -d \"\$ned_path\" ]; then
      echo \"  ERROR: NED package not in container at \$ned_path\"
      exit 1
    fi

    # Create or extend netsim network.
    if [ -d netsim ]; then
      echo '  netsim dir exists — adding devices'
      ncs-netsim --dir netsim ${sub_add} \"\$ned_path\" ${sub_args}
    else
      ncs-netsim --dir netsim ${sub_new} \"\$ned_path\" ${sub_args}
    fi
  " || { echo "==> netsim_up: ${sub_new} failed for ${target}"; fail=1; continue; }
done

[[ "$fail" -ne 0 ]] && exit "$fail"

echo "==> netsim_up: starting netsim devices"
${RUNTIME} exec -u "${NSO_USER}" "${NAME}" sh -lc "
  set -e
  cd /nso/run
  ncs-netsim --dir netsim start
  ncs-netsim --dir netsim list
" | tee reports/netsim-list.log

echo "==> netsim_up: loading device configs into NSO"
# ncs-netsim ncs-xml-init generates XML with <authgroup>default</authgroup>.
# That authgroup must exist in NSO CDB before ncs_load or it fails with
# "bad keyref: illegal reference /ncs:devices/device{…}/authgroup".
# Bootstrap it first with a default-map for the netsim device credentials.
${RUNTIME} exec -u "${NSO_USER}" "${NAME}" sh -lc '
  set -e
  cat > /tmp/authgroup.xml << AGEOF
<config xmlns="http://tail-f.com/ns/config/1.0">
  <devices xmlns="http://tail-f.com/ns/ncs">
    <authgroups>
      <group>
        <name>default</name>
        <default-map>
          <remote-name>'"${NETSIM_DEVICE_USER}"'</remote-name>
          <remote-password>'"${NETSIM_DEVICE_PASSWORD}"'</remote-password>
        </default-map>
      </group>
    </authgroups>
  </devices>
</config>
AGEOF
  ncs_load -l -m -u '"${NSO_ADMIN_USER}"' /tmp/authgroup.xml
' || { echo "==> netsim_up: authgroup bootstrap failed"; exit 1; }

# --dir MUST precede the subcommand (ncs-netsim silently ignores it otherwise).
${RUNTIME} exec -u "${NSO_USER}" "${NAME}" sh -lc '
  set -e
  cd /nso/run
  ncs-netsim --dir netsim ncs-xml-init > /tmp/netsim-devices.xml
  ncs_load -l -m -u '"${NSO_ADMIN_USER}"' /tmp/netsim-devices.xml
' | tee reports/netsim-load.log || { echo "==> netsim_up: ncs_load failed"; fail=1; }

[[ "$fail" -ne 0 ]] && exit "$fail"

echo "==> netsim_up: fetching SSH host keys"
# Commands use -J style (accepts 'request …') and are piped via stdin (not positional arg).
${RUNTIME} exec -i -u "${NSO_USER}" "${NAME}" ncs_cli -u "${NSO_ADMIN_USER}" -J \
  <<<'request devices fetch-ssh-host-keys' | tee reports/netsim-keys.log

echo "==> netsim_up: devices sync-from"
${RUNTIME} exec -i -u "${NSO_USER}" "${NAME}" ncs_cli -u "${NSO_ADMIN_USER}" -J \
  <<<'request devices sync-from' | tee reports/netsim-sync.log

echo "==> netsim_up: verifying sync-from result"
if grep -q 'result false' reports/netsim-sync.log; then
  echo "==> netsim_up: sync-from had errors — FAILING"
  exit 1
fi

echo "==> netsim_up: devices ready"
exit 0
