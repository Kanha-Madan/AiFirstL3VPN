#!/usr/bin/env bash
# CI: release everything a pipeline run allocates on the build agent, whether
# the run passed, failed or was aborted. Wired into the Jenkinsfile in two
# places: `post { always }` (this run's leftovers) and the Prepare stage (leaks
# from earlier runs that died before their own cleanup could run).
#
# Usage: cleanup.sh [build|stale|all]        (default: all)
#   build  this run's own resources, identified by name:
#            - NSO container  ${NSO_CONTAINER_NAME}      (its image too, unless NSO_CLEANUP_IMAGE=false —
#                                                          the pipelines keep it so the next build skips `docker load`)
#            - CXTA container cxta-${NSO_CONTAINER_NAME}
#            - network        nso-test-network-<run id>  (only exists in CXTA_NETWORK_MODE=bridge)
#          The names carry a per-job unique id, so another
#          branch's build with the same build number is never matched.
#   stale  leaks from earlier runs. Only resources we can identify BY NAME are
#          touched — nothing else on the agent is ever removed, and other branch
#          jobs may be building on the same agent at the same time:
#            - containers carrying the label ci.owner=aifirst-nso (or, for leaks
#              from before labels existed, named nso-ci-<N> / cxta-nso-ci-<N>)
#              that are not running, or have been running longer than
#              CLEANUP_STALE_HOURS (default 3; the pipeline timeout is 1h, so a
#              live build is never hit)
#            - networks labelled ci.owner=aifirst-nso or named nso-test-network-*, older than
#              CLEANUP_STALE_NET_MINUTES (default 60) and with no container
#              attached — this is what fixes "all predefined address pools have
#              been fully subnetted"
#          Images are never swept here (no generic `image prune`).
#   all    build + stale
#
# Never fails the build: no `set -e`, every command is best-effort, exit is 0.
set -uo pipefail

MODE="${1:-all}"
RUNTIME="${CONTAINER_RUNTIME:-docker}"
NAME="${NSO_CONTAINER_NAME:-nso-ci}"
STALE_HOURS="${CLEANUP_STALE_HOURS:-3}"
STALE_NET_MINUTES="${CLEANUP_STALE_NET_MINUTES:-60}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Marks everything our scripts create; the stale sweep selects by it.
CI_OWNER_LABEL="ci.owner=aifirst-nso"
# Per-job unique id: NSO_CONTAINER_NAME is nso-ci-<job>-<build> (Jenkinsfile) or
# nso-ci-<run_id> (GitHub Actions), so the network name is unique per job too.
RUN_ID="${NAME#nso-ci}"; RUN_ID="${RUN_ID#-}"
NETWORK_NAME="nso-test-network-${RUN_ID:-local}"

log() { echo "==> cleanup: $*"; }

case "${MODE}" in
  build|stale|all) ;;
  *) echo "usage: $0 [build|stale|all]"; exit 2 ;;
esac

if ! command -v "${RUNTIME}" >/dev/null 2>&1; then
  log "${RUNTIME} not available — nothing to clean"
  exit 0
fi

# remove_container <name> [reason]
# -v also deletes the container's anonymous volumes; without it every build
# leaves its volumes behind on disk.
remove_container() {
  local c="$1" why="${2:-}"
  "${RUNTIME}" container inspect "${c}" >/dev/null 2>&1 || return 0
  if "${RUNTIME}" rm -f -v "${c}" >/dev/null 2>&1; then
    log "removed container ${c}${why:+ (${why})}"
  else
    log "WARNING: could not remove container ${c}"
  fi
}

remove_network() {
  local n="$1"
  "${RUNTIME}" network inspect "${n}" >/dev/null 2>&1 || return 0
  if "${RUNTIME}" network rm "${n}" >/dev/null 2>&1; then
    log "removed network ${n}"
  else
    log "WARNING: could not remove network ${n}"
  fi
}

# Names of every container that is provably ours: labelled by our scripts, or
# (leaks from before labels existed) named exactly nso-ci-<digits>.
our_containers() {
  {
    "${RUNTIME}" ps -a --filter "label=${CI_OWNER_LABEL}" --format '{{.Names}}' 2>/dev/null
    "${RUNTIME}" ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^(cxta-)?nso-ci(-[0-9]+)?$'
  } | sort -u
}

our_networks() {
  {
    "${RUNTIME}" network ls --filter "label=${CI_OWNER_LABEL}" --format '{{.Name}}' 2>/dev/null
    "${RUNTIME}" network ls --format '{{.Name}}' 2>/dev/null | grep -E '^nso-test-network-[A-Za-z0-9._-]+$'
  } | sort -u
}

clean_build() {
  log "this run: NSO container '${NAME}', CXTA container 'cxta-${NAME}', network '${NETWORK_NAME}'"
  remove_container "cxta-${NAME}" "CXTA test container"
  # Removes the NSO container (netsim devices live inside it) and its image.
  NSO_CONTAINER_NAME="${NAME}" bash "${HERE}/setup_nso_container.sh" down || true
  remove_network "${NETWORK_NAME}"
}

clean_stale() {
  log "stale sweep (only our labelled containers not running or > ${STALE_HOURS}h old, and our unused networks > ${STALE_NET_MINUTES}min)"
  local now c n running started ts age_h age_m
  now="$(date +%s)"
  while IFS= read -r c; do
    [[ -z "${c}" ]] && continue
    running="$("${RUNTIME}" inspect -f '{{.State.Running}}' "${c}" 2>/dev/null || echo unknown)"
    if [[ "${running}" != "true" ]]; then
      remove_container "${c}" "stale, not running"
      continue
    fi
    # Running: only remove if far older than any live build can be. `date -d`
    # is GNU (Jenkins agents); if it can't parse, leave the container alone.
    started="$("${RUNTIME}" inspect -f '{{.State.StartedAt}}' "${c}" 2>/dev/null || true)"
    ts="$(date -d "${started}" +%s 2>/dev/null)" || continue
    age_h=$(( (now - ts) / 3600 ))
    if (( age_h >= STALE_HOURS )); then
      remove_container "${c}" "stale, running ${age_h}h"
    fi
  done < <(our_containers || true)

  # Networks: only ours (nso-test-network-*). `network rm` refuses a network
  # that still has a container attached, so a live build is safe; the age check
  # also protects one that was created a moment ago and has no container yet.
  while IFS= read -r n; do
    [[ -z "${n}" ]] && continue
    started="$("${RUNTIME}" network inspect -f '{{json .Created}}' "${n}" 2>/dev/null | tr -d '"' || true)"
    ts="$(date -d "${started}" +%s 2>/dev/null)" || continue
    age_m=$(( (now - ts) / 60 ))
    (( age_m >= STALE_NET_MINUTES )) || continue
    if "${RUNTIME}" network rm "${n}" >/dev/null 2>&1; then
      log "removed network ${n} (stale, ${age_m}min old, unused)"
    fi
  done < <(our_networks || true)
}

case "${MODE}" in
  build) clean_build ;;
  stale) clean_stale ;;
  all)   clean_build; clean_stale ;;
esac

# Leave a footprint in the build log so disk/network pressure is visible.
log "remaining pipeline containers:"
ours="$(our_containers | while IFS= read -r c; do [[ -n "${c}" ]] && "${RUNTIME}" ps -a --filter "name=^${c}$" --format '    {{.Names}}  {{.Status}}' 2>/dev/null; done)"
echo "${ours:-    (none)}"
# Visibility only: every running container on this agent. Only our labelled
# containers are ever removed by this script, so anything else listed here is not ours.
log "all running containers on this agent (never touched unless labelled ci.owner=aifirst-nso):"
"${RUNTIME}" ps --format '    {{.Names}}  image={{.Image}}  {{.Status}}' 2>/dev/null || echo "    (unavailable)"
log "container storage:"
"${RUNTIME}" system df 2>/dev/null | sed 's/^/    /' || true
exit 0
