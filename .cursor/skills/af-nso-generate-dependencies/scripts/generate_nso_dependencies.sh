#!/usr/bin/env bash
# Generate nso-dependencies.yaml from every aifirstspec service-requirements
# spec under aifirstspec/inputs/ (e.g. aifirstspec/inputs/<name>.yaml).
#
# For each SPEC_DIR/<name>.yaml, reads:
#   <name>                                              -> project key name (from the filename)
#   project_metadata.version                            -> project key version (major.minor)
#   development_preferences.nso_version                 -> nso-version
#   <packages-dir>/*/package-meta-data.xml
#     direct <ncs-package>/<name> only (component <name> is ignored)
#     order is <required-package> dependency order, not alphabetical
#                                                       -> nso-packages
#   services[].service_variants[].supported_devices[].ned[].{type,version}
#     (handles both list form `ned: [{type, version}, ...]` and single-map
#     form `ned: {type, version}`)                      -> ned-versions
#
# cxta-version/cxta-image are not part of the aifirstspec schema, so they are
# carried forward from the matching project block already in OUTPUT_FILE (if
# any), falling back to CXTA_VERSION/CXTA_IMAGE env vars or their defaults.
#
# Writes one block per spec file to nso-dependencies.yaml:
#   <project-name> <major.minor>:
#       nso-version: <full-version>
#       nso-packages:
#           - <name from package-meta-data.xml>
#       ned-versions:
#           - <device>-cli-<ned-major.minor>   <ned-version>   <nso-version>
#       cxta-version: <version>
#       cxta-image: <image>
#
# Usage (run from the repo root):
#   agent_primitives/skills/af-nso-generate-dependencies/scripts/generate_nso_dependencies.sh [SPEC_DIR|SPEC_FILE] [OUTPUT_FILE] [PACKAGES_DIR]
#
# Defaults (resolved relative to the current working directory):
#   SPEC_DIR      aifirstspec/inputs
#   OUTPUT_FILE   nso-dependencies.yaml
#   PACKAGES_DIR  packages
set -euo pipefail

SPEC_DIR="${1:-aifirstspec/inputs}"
OUTPUT_FILE="${2:-nso-dependencies.yaml}"
PACKAGES_DIR="${3:-packages}"

CXTA_VERSION_DEFAULT="${CXTA_VERSION:-26.8}"
CXTA_IMAGE_DEFAULT="${CXTA_IMAGE:-dockerhub.cisco.com/cxta-docker/cxta}"

# Portable across bash 3.2 (macOS default) and bash 4+ (CI/Linux) — avoid
# `mapfile`/`readarray`, which macOS's stock /bin/bash does not provide.
SPEC_FILES=()
if [ -f "$SPEC_DIR" ]; then
    SPEC_FILES=("$SPEC_DIR")
elif [ -d "$SPEC_DIR" ]; then
    shopt -s nullglob
    for candidate in "$SPEC_DIR"/*.yaml "$SPEC_DIR"/*.yml; do
        stem="$(basename "$candidate")"
        stem="${stem%.*}"
        # Sidecars are named <spec-id>.<kind>.yaml (e.g. .requirements.yaml); they are not specs.
        case "$stem" in *.*) continue ;; esac
        SPEC_FILES+=("$candidate")
    done
    shopt -u nullglob
else
    echo "ERROR: spec path not found: $SPEC_DIR" >&2
    echo "       Run af-nso-spec-document first to author aifirstspec/inputs/<name>.yaml" >&2
    exit 1
fi

if [ "${#SPEC_FILES[@]}" -eq 0 ]; then
    echo "ERROR: no *.yaml/*.yml spec files found in $SPEC_DIR" >&2
    exit 1
fi

if [ ! -d "$PACKAGES_DIR" ]; then
    echo "ERROR: packages directory not found: $PACKAGES_DIR" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper: print the first "field:" scalar found nested under a top-level
# "block:" key (stops at the next top-level, non-indented key).
# ---------------------------------------------------------------------------
get_nested_value() {
    local file="$1" block="$2" field="$3"
    awk -v block_re="^${block}:" -v field_re="^[[:space:]]+${field}:" '
        $0 ~ block_re { in_block = 1; next }
        in_block && /^[^[:space:]]/ { in_block = 0 }
        in_block && $0 ~ field_re {
            line = $0
            sub(/^[[:space:]]+[A-Za-z0-9_-]+:[[:space:]]*/, "", line)
            gsub(/"/, "", line)
            print line
            exit
        }
    ' "$file"
}

# Package names and compile order come from package-meta-data.xml, not from
# the spec service name and not from alphabetical sorting.
# Direct <ncs-package>/<name> only. A <required-package> is listed before
# every package that requires it. Packages with no such edge keep directory
# discovery order.
read_package_order() {
    PACKAGES_DIR="$PACKAGES_DIR" python3 - << 'PY'
import os
import sys
from collections import defaultdict
from pathlib import Path
import xml.etree.ElementTree as ET

def local(tag):
    return tag.rsplit("}", 1)[-1]

packages_dir = Path(os.environ["PACKAGES_DIR"])
discovered = []
metas = []
# scandir keeps directory order. Do not sort: order comes from dependencies.
with os.scandir(packages_dir) as entries:
    for entry in entries:
        meta = Path(entry.path) / "package-meta-data.xml"
        if entry.is_dir(follow_symlinks=False) and meta.is_file():
            metas.append(meta)

for meta in metas:
    root = ET.parse(meta).getroot()
    name = None
    required = []
    for child in list(root):
        tag = local(child.tag)
        if tag == "name" and name is None:
            name = (child.text or "").strip()
        elif tag == "required-package":
            for nested in list(child):
                if local(nested.tag) == "name" and nested.text and nested.text.strip():
                    required.append(nested.text.strip())
    if not name:
        print(f"ERROR: no <ncs-package>/<name> in {meta}", file=sys.stderr)
        sys.exit(1)
    discovered.append((name, required))

if not discovered:
    print(f"ERROR: no package-meta-data.xml under {packages_dir}", file=sys.stderr)
    sys.exit(1)

known = {name for name, _required in discovered}
deps = {}
for name, required in discovered:
    deps[name] = [req for req in required if req in known]
    external = [req for req in required if req not in known]
    if external:
        print(
            f"  note: {name} requires packages not in {packages_dir}: {', '.join(external)}",
            file=sys.stderr,
        )

dependents = defaultdict(list)
indegree = {name: 0 for name, _required in discovered}
for name, required in deps.items():
    for req in required:
        dependents[req].append(name)
        indegree[name] += 1

ready = [name for name, _required in discovered if indegree[name] == 0]
ordered = []
while ready:
    name = ready.pop(0)
    ordered.append(name)
    for dependent in dependents[name]:
        indegree[dependent] -= 1
        if indegree[dependent] == 0:
            ready.append(dependent)

if len(ordered) < len(discovered):
    print("ERROR: package-meta-data.xml <required-package> graph has a cycle:", file=sys.stderr)
    placed = set(ordered)
    for name, _required in discovered:
        if name not in placed:
            print(f"  - {name}", file=sys.stderr)
    sys.exit(1)

for name, required in discovered:
    local_reqs = deps[name]
    if local_reqs:
        print(f"  package {name} requires: {', '.join(local_reqs)}", file=sys.stderr)
print("\n".join(ordered))
PY
}

# --- nso-packages: <name> from each package-meta-data.xml, dependency order
echo "==> Reading package-meta-data.xml under $PACKAGES_DIR" >&2
PACKAGE_LIST_FILE="$(mktemp)"
trap 'rm -f "$PACKAGE_LIST_FILE" ${EXISTING_FILE:-}' EXIT
if ! read_package_order > "$PACKAGE_LIST_FILE"; then
    echo "ERROR: failed to read package order from $PACKAGES_DIR" >&2
    exit 1
fi
PACKAGES=()
while IFS= read -r name; do
    [ -n "$name" ] && PACKAGES+=("$name")
done < "$PACKAGE_LIST_FILE"

if [ "${#PACKAGES[@]}" -eq 0 ]; then
    echo "ERROR: no packages discovered under $PACKAGES_DIR" >&2
    exit 1
fi

echo "  packages (${#PACKAGES[@]}, dependency order):" >&2
for pkg in "${PACKAGES[@]}"; do
    echo "    - $pkg" >&2
done

# Snapshot the existing output file (before it gets overwritten) so
# cxta-version/cxta-image can be carried forward per project key.
EXISTING_FILE=""
if [ -f "$OUTPUT_FILE" ]; then
    EXISTING_FILE="$OUTPUT_FILE.existing.$$"
    cp "$OUTPUT_FILE" "$EXISTING_FILE"
fi

{
    cat <<'HEADER'
# NSO Dependencies Configuration
# One block per project, generated from aifirstspec/inputs/*.yaml
#
# Format:
#   <project-name> <version>:
#       nso-version: <full nso version>
#       nso-packages:
#           - <name from package-meta-data.xml>
#       ned-versions:
#           - <ned-name>  <ned-version>  <nso-version-for-ned>
#       cxta-version: <cxta version>
#       cxta-image: <cxta image>
#
# Downloads:
#   NSO: https://dl.tail-f.com:9443/ncs/nso-{version}.container-image-build.linux.x86_64.signed.bin
#   NED: https://dl.tail-f.com:9443/ncs-pkgs/{device-type}/{nso-version}/ncs-{nso-version}-{device-type}-{ned-version}.signed.bin
#
# Credentials:
#   - Jenkins: Use credentials ID 'tailf-download-creds' from Jenkins credential store
#   - Local: Set NSO_DOWNLOAD_USER and NSO_DOWNLOAD_PASSWORD environment variables
#
# Generated by agent_primitives/skills/af-nso-generate-dependencies/scripts/generate_nso_dependencies.sh from:
HEADER

    for SPEC_FILE in "${SPEC_FILES[@]}"; do
        echo "#   $SPEC_FILE"
    done
    echo ""

    for SPEC_FILE in "${SPEC_FILES[@]}"; do
        SPEC_BASENAME="$(basename "$SPEC_FILE")"
        PROJECT_NAME="${SPEC_BASENAME%.*}"

        echo "==> Reading spec: $SPEC_BASENAME" >&2

        # --- project version (project_metadata.version, major.minor) -------
        PROJECT_VERSION_FULL="$(get_nested_value "$SPEC_FILE" "project_metadata" "version")"
        if [ -z "$PROJECT_VERSION_FULL" ]; then
            echo "ERROR: no project_metadata.version found in $SPEC_FILE" >&2
            exit 1
        fi
        PROJECT_VERSION_KEY="$(echo "$PROJECT_VERSION_FULL" | cut -d. -f1,2)"
        PROJECT_KEY="${PROJECT_NAME} ${PROJECT_VERSION_KEY}"

        # --- nso version (development_preferences.nso_version) -------------
        NSO_VERSION=$(grep -m1 -E "^[[:space:]]*nso_version:" "$SPEC_FILE" \
            | sed -E 's/^[[:space:]]*nso_version:[[:space:]]*"?([0-9.]+)"?.*/\1/')
        if [ -z "$NSO_VERSION" ]; then
            echo "ERROR: no development_preferences.nso_version found in $SPEC_FILE" >&2
            exit 1
        fi

        # --- ned type/version pairs (supported_devices[].ned[].{type,version})
        # A `type:` line is always immediately followed by its `version:` line
        # in aifirstspec YAML, whether ned is a list entry or a single map.
        NED_PAIRS=()
        while IFS= read -r pair; do
            [ -n "$pair" ] && NED_PAIRS+=("$pair")
        done < <(awk '
            function trim(s) { sub(/^[[:space:]]*-?[[:space:]]*/, "", s); return s }
            /^[[:space:]]*-?[[:space:]]*type:[[:space:]]*"?[A-Za-z0-9_.-]+"?[[:space:]]*$/ {
                t = trim($0)
                sub(/^type:[[:space:]]*/, "", t)
                gsub(/"/, "", t)
                pending_type = t
                next
            }
            /^[[:space:]]*version:[[:space:]]*"?[0-9][0-9.]*"?[[:space:]]*$/ {
                if (pending_type != "") {
                    v = trim($0)
                    sub(/^version:[[:space:]]*/, "", v)
                    gsub(/"/, "", v)
                    print pending_type "|" v
                    pending_type = ""
                }
                next
            }
            { pending_type = "" }
        ' "$SPEC_FILE" | awk 'NF && !seen[$0]++')

        if [ "${#NED_PAIRS[@]}" -eq 0 ]; then
            echo "ERROR: no ned type/version pairs found under supported_devices in $SPEC_FILE" >&2
            exit 1
        fi

        # --- cxta-version/cxta-image: carry forward from the matching -----
        # project block if one already exists, else fall back to defaults.
        CXTA_VERSION=""
        CXTA_IMAGE=""
        if [ -n "$EXISTING_FILE" ]; then
            CXTA_VERSION="$(get_nested_value "$EXISTING_FILE" "$PROJECT_KEY" "cxta-version")"
            CXTA_IMAGE="$(get_nested_value "$EXISTING_FILE" "$PROJECT_KEY" "cxta-image")"
        fi
        CXTA_VERSION="${CXTA_VERSION:-$CXTA_VERSION_DEFAULT}"
        CXTA_IMAGE="${CXTA_IMAGE:-$CXTA_IMAGE_DEFAULT}"

        echo "  project key: $PROJECT_KEY" >&2
        echo "  nso_version: $NSO_VERSION" >&2
        echo "  packages: ${PACKAGES[*]}" >&2
        for pair in "${NED_PAIRS[@]}"; do
            echo "  ned pair: ${pair/|/ }" >&2
        done
        echo "  cxta: $CXTA_VERSION / $CXTA_IMAGE" >&2

        # --- emit the project block ----------------------------------------
        echo "${PROJECT_KEY}:"
        echo "    nso-version: ${NSO_VERSION}"
        echo "    nso-packages:"
        for pkg in "${PACKAGES[@]}"; do
            echo "        - ${pkg}"
        done
        echo "    ned-versions:"
        for pair in "${NED_PAIRS[@]}"; do
            NED_TYPE="${pair%%|*}"
            NED_VER="${pair##*|}"
            # NED name matches the <device>-cli-<major.minor> convention that
            # download_dependencies.sh strips back down to the device type.
            NED_MAJOR_MINOR=$(echo "$NED_VER" | cut -d. -f1,2)
            NED_NAME="${NED_TYPE}-cli-${NED_MAJOR_MINOR}"
            printf '        - %-24s %-12s %s\n' "$NED_NAME" "$NED_VER" "$NSO_VERSION"
        done
        echo "    cxta-version:  ${CXTA_VERSION}"
        echo "    cxta-image:  ${CXTA_IMAGE}"
        echo ""
    done
} > "$OUTPUT_FILE"

echo "==> Wrote $OUTPUT_FILE"
