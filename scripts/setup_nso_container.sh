#!/usr/bin/env bash
# CI: bring up / tear down an NSO container for the pipeline.
# Usage: nso_container.sh up|down
set -euo pipefail

ACTION="${1:-up}"
NAME="${NSO_CONTAINER_NAME:-nso-ci}"
# Marks every container we create so scripts/cleanup.sh can sweep leaks by label
# (and never touches anything else on the agent).
CI_OWNER_LABEL="ci.owner=aifirst-nso"
IMAGE="${NSO_IMAGE:-}"
RUNTIME="${CONTAINER_RUNTIME:-docker}"  # docker or podman
PACKAGES_DIR="${PACKAGES_DIR:-packages}"
NSO_ARTIFACT_BASE_URL="${NSO_ARTIFACT_BASE_URL:-}"
NSO_VERSION="${NSO_VERSION:-6.4}"
# Set NSO_CLEANUP_IMAGE=false to keep the image cached between builds (faster
# subsequent runs but uses ~733 MB of persistent disk space).
NSO_CLEANUP_IMAGE="${NSO_CLEANUP_IMAGE:-true}"
NSO_RESTCONF_USER="${NSO_RESTCONF_USER:-admin}"
NSO_RESTCONF_PASSWORD="${NSO_RESTCONF_PASSWORD:-}"

if [[ "${ACTION}" == "up" && ! "${NSO_RESTCONF_USER}" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,31}$ ]]; then
  echo "ERROR: NSO_RESTCONF_USER has an invalid OS-account name" >&2
  exit 1
fi
if [[ "${ACTION}" == "up" && -z "${NSO_RESTCONF_PASSWORD}" ]]; then
  echo "ERROR: NSO_RESTCONF_PASSWORD must be generated or injected by CI" >&2
  exit 1
fi

# --- Resource guard rails -----------------------------------------------------
# NSO_OOM_SCORE_ADJ : OFF by default. This biases the kernel OOM-killer toward
#                     the NSO container (higher value = killed first). It is a
#                     niche knob for protecting a co-located Jenkins JVM on a
#                     truly RAM-starved host. DO NOT enable it on a host that is
#                     already swapping: it makes NSO the first SIGKILL victim
#                     under any memory pressure, which shows up as the NSO
#                     daemon dying with "status=137" during startup.
# NSO_MEMORY_LIMIT  : optional hard cap (e.g. "3g"). When set, a low-RAM host
#                     fails NSO startup cleanly instead of crashing CI.
# NSO_START_TIMEOUT : seconds to wait for NCS to reach "status: started".
#                     Startup is much slower on a swapping/loaded host, so this
#                     is generous by default.
NSO_OOM_SCORE_ADJ="${NSO_OOM_SCORE_ADJ:-}"
NSO_MEMORY_LIMIT="${NSO_MEMORY_LIMIT:-}"
NSO_MEMORY_SWAP="${NSO_MEMORY_SWAP:-}"
NSO_START_TIMEOUT="${NSO_START_TIMEOUT:-300}"
# NSO_NICE_LEVEL : OS scheduler niceness for the NCS daemon process inside the
#                  container. Higher values lower CPU scheduling priority.
#                  Default 10 reduces startup contention with a co-located
#                  Jenkins JVM while still allowing NSO to come up.
NSO_NICE_LEVEL="${NSO_NICE_LEVEL:-10}"
# NSO_CPU_LIMIT : cap NSO's CPU (e.g. "2"). NSO pegs every core hard during
#                 startup; on a shared Jenkins host that can starve the Jenkins
#                 JVM enough to miss its health/liveness probe, causing Jenkins
#                 to be restarted (~minutes after NSO starts). Capping NSO's CPU
#                 leaves headroom for Jenkins. Recommended on a co-located host.
NSO_CPU_LIMIT="${NSO_CPU_LIMIT:-}"
# NSO_CPU_SHARES : relative CPU priority under contention (Docker default 1024).
#                  Lower values give Jenkins more scheduling preference.
NSO_CPU_SHARES="${NSO_CPU_SHARES:-256}"

# Timeout wrapper using GNU coreutils timeout (standard on Linux/Jenkins).
# macOS ships neither `timeout` nor `gtimeout` by default (not even via
# coreutils unless explicitly installed) — falling back to running the
# command unwrapped there rather than silently swallowing every call as a
# false "command not found" failure (which previously made every ncs --status
# poll look empty, so startup detection never succeeded even once NCS was
# actually up).
if command -v timeout >/dev/null 2>&1; then
  _timeout() { timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then
  _timeout() { gtimeout "$@"; }
else
  echo "==> nso_container: WARNING: no 'timeout'/'gtimeout' binary found — running status checks unwrapped (install coreutils for a hard timeout: brew install coreutils)" >&2
  _timeout() { shift; "$@"; }
fi

# Download helper: use curl or wget, whichever is available
_download() {
  local url="$1"
  local output="$2"
  
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 30 --max-time 300 -o "${output}" "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget --quiet --timeout=300 --tries=3 -O "${output}" "${url}"
  else
    echo "ERROR: Neither curl nor wget is available. Please install one of them." >&2
    return 1
  fi
}

down() {
  echo "==> nso_container: down ${NAME}"
  # Capture the image name before the container is removed so we can clean it up.
  local CONTAINER_IMAGE=""
  if [[ "${NSO_CLEANUP_IMAGE}" == "true" ]]; then
    CONTAINER_IMAGE=$(${RUNTIME} inspect --format '{{.Config.Image}}' "${NAME}" 2>/dev/null || true)
  fi

  # -v also drops the container's anonymous volumes (the NSO image declares
  # some); plain `rm -f` leaves them on disk after every build.
  ${RUNTIME} rm -f -v "${NAME}" >/dev/null 2>&1 || true

  # Remove the loaded image to free disk space (NSO build image is ~733 MB).
  # Skipped if the container was never started or NSO_CLEANUP_IMAGE=false.
  if [[ -n "${CONTAINER_IMAGE}" ]]; then
    echo "==> nso_container: removing image ${CONTAINER_IMAGE}"
    ${RUNTIME} rmi "${CONTAINER_IMAGE}" >/dev/null 2>&1 || true
  fi
}

# Download the NSO container-image signed.bin for the current host architecture,
# extract it, docker-load the image tarball, and set IMAGE to the loaded tag.
load_image_from_artifact() {
  local BASE_URL="${NSO_ARTIFACT_BASE_URL}"
  local EXPECTED_IMAGE="cisco-nso-build:${NSO_VERSION}"

  # Reuse a locally cached NSO image when present to avoid repeated 700MB+
  # downloads/extraction on every replay.
  if ${RUNTIME} image inspect "${EXPECTED_IMAGE}" >/dev/null 2>&1; then
    IMAGE="${EXPECTED_IMAGE}"
    echo "==> nso_container: using cached image '${IMAGE}'"
    return 0
  fi

  # Detect host architecture
  local HOST_ARCH
  HOST_ARCH=$(uname -m)
  local ARCH_SUFFIX
  case "${HOST_ARCH}" in
    x86_64)        ARCH_SUFFIX="x86_64" ;;
    aarch64|arm64) ARCH_SUFFIX="arm64"  ;;
    *)
      echo "ERROR: Unsupported host architecture: ${HOST_ARCH}"
      exit 1
      ;;
  esac

  local BIN_FILE="nso-${NSO_VERSION}.container-image-build.linux.${ARCH_SUFFIX}.signed.bin"
  local LOCAL_BIN="binaries/nso/${BIN_FILE}"
  # Global (not local) so the EXIT trap below can still see it: the extracted
  # image tarball is ~730 MB, and a failure between here and the final
  # `rm -rf` (set -e) would otherwise leave it behind in /tmp on every failed run.
  WORK_DIR=$(mktemp -d)
  trap '[[ -n "${WORK_DIR:-}" ]] && rm -rf "${WORK_DIR}"' EXIT

  # Check if already downloaded locally (from download_dependencies.sh)
  if [[ -f "${LOCAL_BIN}" ]]; then
    echo "==> nso_container: using pre-downloaded ${BIN_FILE} from binaries/nso/"
    cp "${LOCAL_BIN}" "${WORK_DIR}/${BIN_FILE}"
  elif [[ "${BASE_URL}" == file://* ]]; then
    # file:// URL means local workspace path
    LOCAL_PATH="${BASE_URL#file://}/${BIN_FILE}"
    if [[ -f "${LOCAL_PATH}" ]]; then
      echo "==> nso_container: using ${BIN_FILE} from ${LOCAL_PATH}"
      cp "${LOCAL_PATH}" "${WORK_DIR}/${BIN_FILE}"
    else
      echo "ERROR: NSO file not found at ${LOCAL_PATH}"
      echo "       Run download_dependencies.sh first to download NSO"
      rm -rf "${WORK_DIR}"
      exit 1
    fi
  else
    # Download from HTTP/HTTPS URL
    local ARTIFACT_URL="${BASE_URL}/${BIN_FILE}"
    echo "==> nso_container: downloading ${BIN_FILE} (arch=${HOST_ARCH})"
    _download "${ARTIFACT_URL}" "${WORK_DIR}/${BIN_FILE}"
  fi

  echo "==> nso_container: extracting signed.bin"
  chmod +x "${WORK_DIR}/${BIN_FILE}"
  # --skip-verification bypasses Cisco cert check when offline; fall back without it if unsupported
  (cd "${WORK_DIR}" && bash "${BIN_FILE}" --skip-verification 2>/dev/null) || \
  (cd "${WORK_DIR}" && bash "${BIN_FILE}")

  echo "==> nso_container: extracted files:"
  find "${WORK_DIR}" -maxdepth 4 \( -name "*.tar.gz" -o -name "*.tar" \) | sort | while read -r f; do
    echo "    $(du -sh "${f}" 2>/dev/null | cut -f1)  $(basename "${f}")"
  done

  # Identify the Docker image tarball: it must contain 'manifest.json' at the root,
  # which is the format produced by 'docker save'. Other tarballs (e.g. observability
  # exporter) are plain tarballs and do not have this file.
  local TAR_FILE=""
  while IFS= read -r candidate; do
    local list_cmd
    if [[ "${candidate}" == *.tar.gz ]]; then
      list_cmd="tar -tzf"
    else
      list_cmd="tar -tf"
    fi
    if ${list_cmd} "${candidate}" 2>/dev/null | grep -qE "^manifest\.json$"; then
      TAR_FILE="${candidate}"
      break
    fi
  done < <(find "${WORK_DIR}" -maxdepth 4 \( -name "*.tar.gz" -o -name "*.tar" \) | sort)

  # Fallback: largest tarball (NSO image is typically hundreds of MB)
  if [[ -z "${TAR_FILE}" ]]; then
    echo "WARNING: No tarball with Docker manifest.json found; falling back to largest tarball"
    TAR_FILE=$(find "${WORK_DIR}" -maxdepth 4 \( -name "*.tar.gz" -o -name "*.tar" \) \
      -exec ls -s {} \; 2>/dev/null | sort -rn | head -1 | awk '{print $2}')
  fi

  if [[ -z "${TAR_FILE}" ]]; then
    echo "ERROR: No image tarball found after extracting ${BIN_FILE}"
    ls -laR "${WORK_DIR}"
    rm -rf "${WORK_DIR}"
    exit 1
  fi

  echo "==> nso_container: loading image from $(basename "${TAR_FILE}")"
  local LOAD_OUTPUT
  LOAD_OUTPUT=$(${RUNTIME} load -i "${TAR_FILE}")
  echo "${LOAD_OUTPUT}"
  # Extract tag from "Loaded image: <repo>:<tag>" line
  IMAGE=$(echo "${LOAD_OUTPUT}" | grep -E "^Loaded image:" | sed 's/^Loaded image:[[:space:]]*//' | tail -1)
  if [[ -z "${IMAGE}" ]]; then
    # Fallback: grab the most-recently-added image
    IMAGE=$(${RUNTIME} images --format '{{.Repository}}:{{.Tag}}' | head -1)
  fi
  echo "==> nso_container: loaded image as '${IMAGE}'"
  rm -rf "${WORK_DIR}"
}

up() {
  # If no registry image given, download the signed.bin from the artifact server
  if [[ -z "${IMAGE}" ]]; then
    if [[ -z "${NSO_ARTIFACT_BASE_URL}" ]]; then
      echo "ERROR: Neither NSO_IMAGE nor NSO_ARTIFACT_BASE_URL is set."
      echo "       Set NSO_IMAGE to a registry URL, or set NSO_ARTIFACT_BASE_URL"
      echo "       to the base URL hosting nso-<ver>.container-image-build.linux.<arch>.signed.bin"
      exit 1
    fi
    load_image_from_artifact
  else
    # Login to private registry if credentials are provided (set via Jenkins withCredentials).
    if [[ -n "${REGISTRY_USER:-}" && -n "${REGISTRY_TOKEN:-}" ]]; then
      REGISTRY_HOST="$(echo "${IMAGE}" | cut -d'/' -f1)"
      echo "==> nso_container: logging in to ${REGISTRY_HOST}"
      echo "${REGISTRY_TOKEN}" | ${RUNTIME} login -u "${REGISTRY_USER}" --password-stdin "${REGISTRY_HOST}"
    fi
  fi

  down
  echo "==> nso_container: up image=${IMAGE}"
  # Explicit platform avoids the "image's platform does not match host" warning.
  # NSO_PLATFORM overrides the host-derived default for cross-architecture support.
  local PLATFORM_FLAG=""
  if [[ -n "${NSO_PLATFORM:-}" ]]; then
    PLATFORM_FLAG="--platform ${NSO_PLATFORM}"
  else
    case "$(uname -m)" in
      x86_64)        PLATFORM_FLAG="--platform linux/amd64" ;;
      aarch64|arm64) PLATFORM_FLAG="--platform linux/arm64" ;;
    esac
  fi
  # Optional resource guard rails (see top of file). Both are OFF by default.
  local RESOURCE_FLAGS=""
  if [[ -n "${NSO_MEMORY_LIMIT}" ]]; then
    RESOURCE_FLAGS="--memory=${NSO_MEMORY_LIMIT} --memory-swap=${NSO_MEMORY_SWAP:-${NSO_MEMORY_LIMIT}}"
    echo "==> nso_container: memory cap=${NSO_MEMORY_LIMIT} (swap=${NSO_MEMORY_SWAP:-${NSO_MEMORY_LIMIT}})"
  fi
  if [[ -n "${NSO_CPU_LIMIT}" ]]; then
    RESOURCE_FLAGS="${RESOURCE_FLAGS} --cpus=${NSO_CPU_LIMIT}"
    echo "==> nso_container: cpu cap=${NSO_CPU_LIMIT} (leaves CPU headroom for Jenkins)"
  fi
  if [[ -n "${NSO_CPU_SHARES}" ]]; then
    RESOURCE_FLAGS="${RESOURCE_FLAGS} --cpu-shares=${NSO_CPU_SHARES}"
    echo "==> nso_container: cpu shares=${NSO_CPU_SHARES} (lower than 1024 favors Jenkins under contention)"
  fi
  local OOM_FLAG=""
  if [[ -n "${NSO_OOM_SCORE_ADJ}" ]]; then
    OOM_FLAG="--oom-score-adj=${NSO_OOM_SCORE_ADJ}"
    echo "==> nso_container: oom-score-adj=${NSO_OOM_SCORE_ADJ} (NSO biased as OOM victim)"
  fi

  echo "==> nso_container: host memory before NSO start:"
  free -h 2>/dev/null || free -m 2>/dev/null || echo "    (free not available on this agent)"

  # No host port mappings — Jenkins talks to NSO via `${RUNTIME} exec`, not via host network.
  # Packages are copied in by setup_packages.sh (workspace path may not be reachable from a sibling container).
  # If the optional OOM flag is rejected by the runtime/kernel, retry without it.
  # shellcheck disable=SC2086
  ${RUNTIME} run -d ${PLATFORM_FLAG} ${RESOURCE_FLAGS} ${OOM_FLAG} --label "${CI_OWNER_LABEL}" --name "${NAME}" "${IMAGE}" >/dev/null 2>/tmp/nso_run_err.$$ || {
    if [[ -n "${OOM_FLAG}" ]]; then
      echo "==> nso_container: 'run ${OOM_FLAG}' rejected — retrying without it"
      cat "/tmp/nso_run_err.$$" 2>/dev/null || true
      ${RUNTIME} rm -f "${NAME}" >/dev/null 2>&1 || true
      # shellcheck disable=SC2086
      ${RUNTIME} run -d ${PLATFORM_FLAG} ${RESOURCE_FLAGS} --label "${CI_OWNER_LABEL}" --name "${NAME}" "${IMAGE}" >/dev/null
    else
      cat "/tmp/nso_run_err.$$" 2>/dev/null || true
      rm -f "/tmp/nso_run_err.$$" 2>/dev/null || true
      exit 1
    fi
  }
  rm -f "/tmp/nso_run_err.$$" 2>/dev/null || true

  # Detect runtime user: prefer `nso` if it exists (prod / 6.7 build images), otherwise root (6.4 build image).
  if ${RUNTIME} exec -u 0 "${NAME}" id nso >/dev/null 2>&1; then
    NSO_USER="nso"
  else
    NSO_USER="root"
  fi
  echo "==> nso_container: runtime user='${NSO_USER}'"

  echo "==> nso_container: tailoring image (root): /nso/run, /log, /var/log/ncs, crypto keys"
  ${RUNTIME} exec -u 0 "${NAME}" sh -lc "
    set -e
    mkdir -p /log /var/log/ncs /nso/run/packages /nso/run/scripts /nso/run/state /nso/run/cdb /nso/run/rollbacks /nso/run/streams
    chown -R ${NSO_USER}: /log /var/log/ncs /nso/run 2>/dev/null || chown -R ${NSO_USER} /log /var/log/ncs /nso/run
    if [ ! -s /etc/ncs/ncs.crypto_keys ]; then
      printf 'AESCFB128_KEY=%s\nAES256CFB128_KEY=%s\n' \
        \"\$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')\" \
        \"\$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')\" \
        > /etc/ncs/ncs.crypto_keys
      chmod 600 /etc/ncs/ncs.crypto_keys
      chown ${NSO_USER} /etc/ncs/ncs.crypto_keys
    fi
    # Some NSO build images (notably 6.4) ship ncs.conf with \${NCS_RUN_DIR} / \${NCS_LOG_DIR}
    # placeholders that the daemon does not expand at load time, falling back to /var/opt/ncs/...
    # Inline-substitute with the values from the container ENV so ncs can start.
    if grep -q '\${NCS_RUN_DIR}\\|\${NCS_LOG_DIR}\\|\${NCS_DIR}\\|\${NCS_CONFIG_DIR}' /etc/ncs/ncs.conf; then
      sed -i \
        -e \"s|\\\${NCS_RUN_DIR}|\${NCS_RUN_DIR:-/nso/run}|g\" \
        -e \"s|\\\${NCS_LOG_DIR}|\${NCS_LOG_DIR:-/log}|g\" \
        -e \"s|\\\${NCS_DIR}|\${NCS_DIR:-/opt/ncs/current}|g\" \
        -e \"s|\\\${NCS_CONFIG_DIR}|\${NCS_CONFIG_DIR:-/etc/ncs}|g\" \
        /etc/ncs/ncs.conf
      echo '==> nso_container: substituted env-var placeholders in /etc/ncs/ncs.conf'
    fi
    # The base image ships the webui HTTP transport (which also serves RESTCONF
    # on port 8080) disabled. Without this, nothing listens on 8080 and every
    # RESTCONF/CXTA call gets connection-refused regardless of networking.
    sed -i -z \
      's#<tcp>\n        <enabled>false</enabled>\n        <ip>0.0.0.0</ip>\n        <port>8080</port>#<tcp>\n        <enabled>true</enabled>\n        <ip>0.0.0.0</ip>\n        <port>8080</port>#' \
      /etc/ncs/ncs.conf
    # NSO 6.7+ images ship the transport flag as an env-var expression
    # (<enabled>\${NCS_WEBUI_TRANSPORT_TCP:-false}</enabled>) instead of a literal
    # false, so the pattern above does not match. Handle that form too.
    sed -i 's#\${NCS_WEBUI_TRANSPORT_TCP:-false}#true#' /etc/ncs/ncs.conf
    # 6.7 also ships <match-host-name> on by default, which rejects requests whose
    # Host header is not the configured server name (HTTP 400). CI clients reach
    # NSO as 127.0.0.1, so turn it off. No-op on images without the expression.
    sed -i 's#\${NCS_WEBUI_MATCH_HOST_NAME:-true}#false#' /etc/ncs/ncs.conf
    # Fail loudly rather than silently leaving 8080 closed (every RESTCONF/CXTA
    # call would otherwise fail later with connection-refused).
    if ! grep -B2 '<port>8080</port>' /etc/ncs/ncs.conf | grep -q '<enabled>true</enabled>'; then
      echo '==> nso_container: ERROR: could not enable the webui HTTP transport (port 8080) in /etc/ncs/ncs.conf' >&2
      grep -n -B3 -A3 '<port>8080</port>' /etc/ncs/ncs.conf >&2 || true
      exit 1
    fi
    echo '==> nso_container: enabled RESTCONF/webui HTTP transport (port 8080) in /etc/ncs/ncs.conf'

    # ncs.conf has <pam><enabled>true</pam> and <local-authentication>false</local-authentication>,
    # so external transports (RESTCONF/NETCONF/CLI-over-SSH) authenticate
    # against a real OS account, not NSO's own CDB users. The image ships
    # neither. Mirrors the reference Jenkinsfile's tailor_dkr_image(): the
    # 'ncsadmin' group name doubles as the NACM group PAM-authenticated users
    # land in (see the NACM bootstrap below).
    groupadd ncsadmin 2>/dev/null || true
  "
  ${RUNTIME} exec -u 0 \
    -e NSO_RESTCONF_USER -e NSO_RESTCONF_PASSWORD -e "NSO_RUN_USER=${NSO_USER}" \
    "${NAME}" sh -lc '
      set -e
      id "${NSO_RESTCONF_USER}" >/dev/null 2>&1 ||
        useradd -m -g ncsadmin -- "${NSO_RESTCONF_USER}"
      usermod -aG ncsadmin -- "${NSO_RESTCONF_USER}" 2>/dev/null || true
      printf "%s:%s\n" "${NSO_RESTCONF_USER}" "${NSO_RESTCONF_PASSWORD}" | chpasswd
      echo "==> nso_container: provisioned disposable RESTCONF account"
      # NSO 6.7+ images run ncs as the non-root "nso" user. PAM (pam_unix) can
      # then only verify the calling user own password through unix_chkpwd, so every
      # RESTCONF login for another OS account fails with 401. Let the ncs user read
      # /etc/shadow so pam_unix can authenticate the account above. Scoped to this
      # throwaway CI container; skipped when ncs already runs as root (6.4).
      if [ "${NSO_RUN_USER}" != "root" ]; then
        chgrp "${NSO_RUN_USER}" /etc/shadow && chmod 640 /etc/shadow
        echo "==> nso_container: granted ${NSO_RUN_USER} read access to /etc/shadow for PAM auth"
      fi
    '

  echo "==> nso_container: starting ncs daemon (as ${NSO_USER})"
  # Some NSO images auto-start NCS via the entrypoint. Check first so we do
  # not try to start a second instance (which would hang on the lock file).
  if _timeout 10 ${RUNTIME} exec -u "${NSO_USER}" "${NAME}" \
      ncs --status -c /etc/ncs/ncs.conf 2>/dev/null | grep -q "^status: started"; then
    echo "==> nso_container: ncs already running — skipping startup"
  else
    # Start NCS *detached* (`exec -d`) with its output redirected to a file
    # inside the container. Two reasons:
    #   1. The NCS daemon and its Java/Python child VMs must NOT inherit the
    #      `${RUNTIME} exec` fds. Under Jenkins those fds are the durable-task
    #      log pipe; a long-lived daemon holding it open hangs the step with
    #      JENKINS-48300 ("wrapper script does not seem to be touching the log
    #      file"). `-d` + redirect fully detaches it.
    #   2. We must NOT wrap the start in a foreground `timeout`. On a loaded /
    #      swapping host NCS startup is slow; a foreground timeout that fires
    #      mid-startup tears down the half-initialised daemon, which surfaces as
    #      "Daemon died status=137" (SIGKILL). Detached start + a polling
    #      readiness loop lets NCS take as long as it legitimately needs.
    echo "==> nso_container: launching ncs (detached), waiting up to ${NSO_START_TIMEOUT}s"
    ${RUNTIME} exec -d -u "${NSO_USER}" "${NAME}" \
      sh -lc "cd /nso/run && exec nice -n ${NSO_NICE_LEVEL} ncs -c /etc/ncs/ncs.conf </dev/null >/log/ncs-start.out 2>&1"

    # Poll `ncs --status` until "started". Print progress each iteration so the
    # Jenkins durable-task wrapper keeps seeing fresh log output (avoids the
    # JENKINS-48300 heartbeat timeout during a slow startup).
    local ncs_ready=false
    local elapsed=0
    local i=0
    while [[ "${elapsed}" -lt "${NSO_START_TIMEOUT}" ]]; do
      i=$((i + 1))
      echo "==> nso_container: status check ${i} (${elapsed}s/${NSO_START_TIMEOUT}s) ..."
      out=$(_timeout 8 ${RUNTIME} exec -u "${NSO_USER}" "${NAME}" \
            ncs --status -c /etc/ncs/ncs.conf 2>/dev/null || true)
      if printf '%s' "${out}" | grep -q "^status: started"; then
        ncs_ready=true
        break
      fi
      # Surface an early hard failure (e.g. NSO printed "Daemon died") instead
      # of waiting out the whole timeout.
      if _timeout 5 ${RUNTIME} exec -u 0 "${NAME}" grep -qi "daemon died\|fatal\|aborting" /log/ncs-start.out 2>/dev/null; then
        echo "==> nso_container: NCS reported a fatal startup error:"
        ${RUNTIME} exec -u 0 "${NAME}" sh -lc 'cat /log/ncs-start.out 2>/dev/null' || true
        break
      fi
      sleep 3
      elapsed=$((elapsed + 3))
    done

    if [[ "${ncs_ready}" != "true" ]]; then
      echo "==> nso_container: ncs failed to start (waited ${elapsed}s)"
      echo "--- /log/ncs-start.out ---"
      ${RUNTIME} exec -u 0 "${NAME}" sh -lc 'cat /log/ncs-start.out 2>/dev/null; echo; tail -120 /log/ncs.log 2>/dev/null; tail -80 /log/ncserr.log* 2>/dev/null; tail -80 /log/ncs-python-vm.log 2>/dev/null' || true
      # Was the container's main process OOM-killed? (status=137 hint)
      local oom_killed
      oom_killed=$(${RUNTIME} inspect --format '{{.State.OOMKilled}}' "${NAME}" 2>/dev/null || echo "unknown")
      echo "==> nso_container: container OOMKilled=${oom_killed}"
      echo "==> nso_container: host memory at failure:"
      free -h 2>/dev/null || free -m 2>/dev/null || true
      exit 1
    fi
  fi

  echo "==> nso_container: ready"

  # PAM only authenticates; NACM still has to authorize the resulting session.
  # No aaa_init.xml ships in this image, so the CDB has zero NACM groups —
  # without this, PAM authentication succeeds but every RESTCONF request is
  # denied. Loaded via local trusted IPC (ncs_load -l -m), so no external auth
  # is needed here. Idempotent: NACM groups/rule-lists are merge-safe on repeat runs.
  ${RUNTIME} exec -u "${NSO_USER}" -e NSO_RESTCONF_USER "${NAME}" sh -lc '
    cat > /tmp/nacm_init.xml << "NACMEOF"
<config xmlns="http://tail-f.com/ns/config/1.0">
  <nacm xmlns="urn:ietf:params:xml:ns:yang:ietf-netconf-acm">
    <enable-nacm>true</enable-nacm>
    <read-default>permit</read-default>
    <write-default>permit</write-default>
    <exec-default>permit</exec-default>
    <groups>
      <group>
        <name>ncsadmin</name>
        <user-name>__NSO_RESTCONF_USER__</user-name>
      </group>
    </groups>
    <rule-list>
      <name>ncsadmin</name>
      <group>ncsadmin</group>
      <rule>
        <name>any-access</name>
        <module-name>*</module-name>
        <access-operations>*</access-operations>
        <action>permit</action>
      </rule>
    </rule-list>
  </nacm>
</config>
NACMEOF
    sed -i "s/__NSO_RESTCONF_USER__/${NSO_RESTCONF_USER}/g" /tmp/nacm_init.xml
    ncs_load -l -m -u "${NSO_RESTCONF_USER}" /tmp/nacm_init.xml && rm -f /tmp/nacm_init.xml
  ' && echo "==> nso_container: bootstrapped NACM ncsadmin group (RESTCONF user -> full access)"

  # Record NSO's footprint so memory sizing is visible in the build log.
  echo "==> nso_container: NSO resource usage:"
  ${RUNTIME} stats --no-stream "${NAME}" 2>/dev/null || true
  echo "==> nso_container: host memory after NSO start:"
  free -h 2>/dev/null || free -m 2>/dev/null || true
}

case "${ACTION}" in
  up)   up ;;
  down) down ;;
  *) echo "usage: $0 up|down"; exit 2 ;;
esac
