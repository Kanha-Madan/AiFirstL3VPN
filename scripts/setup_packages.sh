#!/usr/bin/env bash
# CI: compile every package against the running NSO container, then `packages reload force`.
#
# Compile order comes from nso-dependencies.yaml, not directory/alphabetical
# discovery:
#   1. NEDs (every `ned-versions:` entry, across every project block) — built
#      first, in the order listed, since service packages may depend on NED
#      YANG modules.
#   2. Declared service packages (every `nso-packages:` entry, across every
#      project block, in the order listed — that list is dependency order,
#      produced by a topological sort over each package's
#      <required-package> graph, not alphabetical).
#   3. Anything else found under PACKAGES_DIR that isn't declared in either
#      list above ("undeclared") — built last, with a WARNING, so a real
#      package on disk is never silently skipped just because the manifest
#      doesn't know about it yet.
#
# The project key at the top of each nso-dependencies.yaml block (e.g.
# "example-l3vpn 0.1:") is free-form and ignored here — only the nested
# `nso-version:`, `nso-packages:`, and `ned-versions:` fields matter, so any
# number of differently-named project blocks are supported.
#
# Mismatches between the manifest and PACKAGES_DIR are expected occasionally
# (packages/ not yet scaffolded, a package renamed, etc.) and are always
# reported. Whether a *missing* declared package (in nso-packages/ned-versions
# but not found on disk) fails the build is controlled by
# STRICT_PACKAGE_ORDER (default: false — warn only). Undeclared extras never
# fail the build either way; they are simply compiled and flagged.
#
# Default is warn-only because packages/** is gitignored (see AGENTS.md) and
# neither this pipeline nor its GitHub Actions twin currently has a step that
# builds/generates the declared service packages into PACKAGES_DIR during
# CI — only NEDs get materialized there (via download_dependencies.sh). So a
# fresh CI checkout *always* has declared service packages "missing" today;
# that's the normal state, not manifest/repo drift. Flip
# STRICT_PACKAGE_ORDER=true once CI actually builds/checks in every declared
# package, to catch real drift going forward.
set -euo pipefail

PACKAGES_DIR="${PACKAGES_DIR:-packages}"
NAME="${NSO_CONTAINER_NAME:-nso-ci}"
RUNTIME="${CONTAINER_RUNTIME:-docker}"
DEPENDENCIES_FILE="${NSO_DEPENDENCIES_FILE:-nso-dependencies.yaml}"
# Set to "true" to fail the build (not just warn) when nso-dependencies.yaml
# declares a package/NED that isn't present under PACKAGES_DIR.
STRICT_PACKAGE_ORDER="${STRICT_PACKAGE_ORDER:-false}"

if ! ${RUNTIME} ps --format '{{.Names}}' | grep -qx "${NAME}"; then
  echo "==> setup_packages: NSO container '${NAME}' not running — FAILING"
  exit 1
fi

# Match runtime user used by nso_container.sh (nso for prod/6.7-build, root for 6.4-build).
if ${RUNTIME} exec -u 0 "${NAME}" id nso >/dev/null 2>&1; then
  NSO_USER="nso"
else
  NSO_USER="root"
fi

# NSO CLI admin identity (not the container OS user above) — override via env.
NSO_ADMIN_USER="${NSO_ADMIN_USER:-admin}"

# ---------------------------------------------------------------------------
# Small bash-3.2/4-portable "does array contain value" helper (no
# associative arrays / mapfile assumptions beyond what's already used
# elsewhere in scripts/, kept simple since these lists are tiny).
# ---------------------------------------------------------------------------
_contains() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Read the declared compile order from nso-dependencies.yaml. Falls back to
# empty lists (pure discovery order, previous behavior) with a warning if the
# file is missing/unreadable.
# ---------------------------------------------------------------------------
NED_NAMES=()
DECLARED_PACKAGES=()
DEPS_FILE_PRESENT=false

if [[ -f "${DEPENDENCIES_FILE}" ]]; then
  DEPS_FILE_PRESENT=true
  # NED entries: "        - cisco-iosxr-cli-7.61     7.61.4       6.4.1" -> field 2.
  # Same convention download_dependencies.sh already relies on.
  mapfile -t NED_NAMES < <(
    grep -E "^[[:space:]]+-[[:space:]]+cisco-" "${DEPENDENCIES_FILE}" \
      | awk '{print $2}' | awk '!seen[$0]++'
  )

  # nso-packages: list items, collected across every project block in the
  # file, in the order they appear (dependency order from the generator).
  mapfile -t DECLARED_PACKAGES < <(
    awk '
      /^[[:space:]]+nso-packages:[[:space:]]*$/ { in_block = 1; next }
      in_block && /^[[:space:]]+-[[:space:]]+[^[:space:]]/ {
        line = $0
        sub(/^[[:space:]]+-[[:space:]]+/, "", line)
        gsub(/[[:space:]]+$/, "", line)
        print line
        next
      }
      { in_block = 0 }
    ' "${DEPENDENCIES_FILE}" | awk '!seen[$0]++'
  )
else
  echo "==> setup_packages: WARNING: ${DEPENDENCIES_FILE} not found — falling back to alphabetical discovery order"
fi

# ---------------------------------------------------------------------------
# Discover buildable packages on disk (must have package-meta-data.xml).
# Directory basename is treated as the package name — consistent with how
# nso-packages/ned-versions names are generated (scaffolded package dirs and
# extracted NED dirs are named after the package identity).
# ---------------------------------------------------------------------------
shopt -s nullglob
DISCOVERED=()
for pkg_dir in "${PACKAGES_DIR}"/*/; do
  [[ -f "${pkg_dir}/package-meta-data.xml" ]] || continue
  DISCOVERED+=("$(basename "${pkg_dir%/}")")
done
shopt -u nullglob

# ---------------------------------------------------------------------------
# Build the final compile order: NEDs -> declared packages -> undeclared
# extras. Track what's missing (declared but absent) and undeclared (present
# but not declared) for reporting / the strict-mode gate.
# ---------------------------------------------------------------------------
COMPILE_ORDER=()
MISSING_PACKAGES=()
UNDECLARED_PACKAGES=()

for ned in "${NED_NAMES[@]}"; do
  if _contains "${ned}" "${DISCOVERED[@]}"; then
    _contains "${ned}" "${COMPILE_ORDER[@]}" || COMPILE_ORDER+=("${ned}")
  else
    MISSING_PACKAGES+=("${ned}")
  fi
done

for pkg in "${DECLARED_PACKAGES[@]}"; do
  _contains "${pkg}" "${COMPILE_ORDER[@]}" && continue
  if _contains "${pkg}" "${DISCOVERED[@]}"; then
    COMPILE_ORDER+=("${pkg}")
  else
    MISSING_PACKAGES+=("${pkg}")
  fi
done

for pkg in "${DISCOVERED[@]}"; do
  if ! _contains "${pkg}" "${COMPILE_ORDER[@]}"; then
    COMPILE_ORDER+=("${pkg}")
    UNDECLARED_PACKAGES+=("${pkg}")
  fi
done

if [[ "${DEPS_FILE_PRESENT}" == "true" && "${#NED_NAMES[@]}" -eq 0 && "${#DECLARED_PACKAGES[@]}" -eq 0 ]]; then
  echo "==> setup_packages: WARNING: no nso-packages/ned-versions entries found in ${DEPENDENCIES_FILE} — using discovery order"
fi

if [[ "${DEPS_FILE_PRESENT}" == "true" && "${#MISSING_PACKAGES[@]}" -gt 0 ]]; then
  echo "==> setup_packages: WARNING: ${DEPENDENCIES_FILE} declares packages/NEDs not found under ${PACKAGES_DIR} (missing directory or package-meta-data.xml not yet built):"
  for pkg in "${MISSING_PACKAGES[@]}"; do
    echo "      - ${pkg}"
  done
fi

# Only meaningful when there's an actual manifest to have been declared in —
# with no nso-dependencies.yaml at all, everything on disk is "undeclared" by
# definition and calling that out would just be noise around plain discovery
# order.
if [[ "${DEPS_FILE_PRESENT}" == "true" && "${#UNDECLARED_PACKAGES[@]}" -gt 0 ]]; then
  echo "==> setup_packages: WARNING: packages found under ${PACKAGES_DIR} that are NOT declared in nso-packages/ned-versions (building anyway, appended last):"
  for pkg in "${UNDECLARED_PACKAGES[@]}"; do
    echo "      - ${pkg}"
  done
fi

echo "==> setup_packages: compile order (${#COMPILE_ORDER[@]} package(s)):"
for pkg in "${COMPILE_ORDER[@]}"; do
  echo "      - ${pkg}"
done

mkdir -p reports

if [[ "${#COMPILE_ORDER[@]}" -eq 0 ]]; then
  echo "==> setup_packages: no buildable packages found under ${PACKAGES_DIR} — skipping build stage"
fi

fail=0
for pkg_name in "${COMPILE_ORDER[@]}"; do
  pkg_dir="${PACKAGES_DIR}/${pkg_name}"
  echo "---- ${pkg_name} ----"

  # Copy package into the container, then build it there.
  # Stream via tar | exec -i so it works with sibling-container engines (host daemon
  # cannot see this container's filesystem, but stdin works).
  # Exclude ._* metadata files and use GNU tar standard behavior for Linux.
  ${RUNTIME} exec -u "${NSO_USER}" "${NAME}" sh -lc "rm -rf /nso/run/packages/${pkg_name}"
  tar -C "${PACKAGES_DIR}" --exclude='._*' -cf - "${pkg_name}" \
    | ${RUNTIME} exec -i -u "${NSO_USER}" "${NAME}" tar -C /nso/run/packages -xf - \
    || { fail=1; continue; }
  ${RUNTIME} exec -u "${NSO_USER}" "${NAME}" sh -lc "
    set -e
    pkg=/nso/run/packages/${pkg_name}
    if [ -f \"\$pkg/src/Makefile\" ]; then
      make -C \"\$pkg/src\" clean all
    elif ls \"\$pkg\"/load-dir/*.fxs >/dev/null 2>&1; then
      echo \"  no src/Makefile — using shipped load-dir artifacts\"
    else
      echo \"  no src/Makefile and no load-dir artifacts — nothing to do\"
    fi
  " || { fail=1; continue; }
done

# Count packages actually built (not just declared).
pkg_count="${#COMPILE_ORDER[@]}"

if [[ ${pkg_count} -eq 0 ]]; then
  echo "==> setup_packages: no packages found in ${PACKAGES_DIR} — skipping reload"
else
  echo "==> setup_packages: packages reload force"
  # Note: ncs_cli's -C is Cisco-XR style (no `request` verb); -J is Juniper style which accepts `request ...`.
  # The command is fed via stdin because -C/-J's positional arg is treated as a file path, not a command.

  # Check if there are any compiled FXS files to load
  if ! find "${PACKAGES_DIR}" -name "*.fxs" 2>/dev/null | grep -q .; then
    echo "==> setup_packages: no compiled packages (.fxs files) found — skipping reload"
  else
    set -o pipefail
    ${RUNTIME} exec -i -u "${NSO_USER}" "${NAME}" ncs_cli -u "${NSO_ADMIN_USER}" -J <<<'request packages reload force' \
      | tee reports/packages-reload.log || fail=1
    set +o pipefail
    if grep -E 'Failed to load|result false|^Error:' reports/packages-reload.log >/dev/null; then
      echo "==> setup_packages: reload reported errors — FAILING"
      fail=1
    fi

    echo "==> setup_packages: verifying oper-status up"
    ${RUNTIME} exec -i -u "${NSO_USER}" "${NAME}" ncs_cli -u "${NSO_ADMIN_USER}" -C <<<'show packages package oper-status' | tee reports/packages-status.log
    if grep -E 'No entries found' reports/packages-status.log >/dev/null; then
      echo "==> setup_packages: NSO sees no packages — INFO (template package, no artifacts)"
    fi
    if grep -E 'oper-status (error|program-code-error|init|undefined|file-load-error)' reports/packages-status.log; then
      echo "==> setup_packages: at least one package not 'up' — FAILING"
      fail=1
    fi
  fi
fi

# Optional manifest/repo drift gate: a package or NED declared in
# nso-dependencies.yaml but absent from PACKAGES_DIR *can* mean a stale
# manifest or incomplete checkout/build — but off by default (see
# STRICT_PACKAGE_ORDER comment above) since it's also the normal state until
# CI actually builds every declared package. The WARNING was already printed
# above regardless of this flag.
if [[ "${#MISSING_PACKAGES[@]}" -gt 0 && "${STRICT_PACKAGE_ORDER}" == "true" ]]; then
  echo "==> setup_packages: FAILING — ${#MISSING_PACKAGES[@]} package(s)/NED(s) declared in ${DEPENDENCIES_FILE} were not found under ${PACKAGES_DIR} (set STRICT_PACKAGE_ORDER=false to only warn)"
  fail=1
fi

exit "${fail}"
