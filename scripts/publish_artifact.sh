#!/usr/bin/env bash
# CI: bundle every built package into a single, traceable archive.
#
# Historically this produced one .tar.gz per package, which meant CD had to
# copy+extract N files per deploy. Instead we now bundle the whole packages/
# tree into one archive (named nso-packages-<sha>-<build>.tar.gz) so deploy
# only ever has to copy and extract a single file. manifest.json still lists
# each package that went into the bundle plus the bundle's own checksum.
set -euo pipefail

PACKAGES_DIR="${PACKAGES_DIR:-packages}"
ARTIFACT_DIR="${ARTIFACT_DIR:-.artifacts}"
BUILD_ID="${BUILD_ID:-${BUILD_NUMBER:-local}}"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
NSO_VERSION="${NSO_VERSION:-unknown}"

mkdir -p "${ARTIFACT_DIR}"

# Drop any combined bundle left over from a previous build in this workspace
# (Jenkins workspaces persist across builds) so deploy_packages.sh never sees
# more than one candidate archive.
rm -f "${ARTIFACT_DIR}"/nso-packages-*.tar.gz

shopt -s nullglob
pkg_names=()
for pkg_dir in "${PACKAGES_DIR}"/*/; do
  [[ -f "${pkg_dir}/package-meta-data.xml" ]] || continue
  pkg_names+=("$(basename "${pkg_dir%/}")")
done

if [[ ${#pkg_names[@]} -eq 0 ]]; then
  echo "==> publish: no packages found under ${PACKAGES_DIR} — FAILING (publish must produce at least one artifact)"
  exit 1
fi

archive_name="nso-packages-${GIT_SHA}-${BUILD_ID}.tar.gz"
out="${ARTIFACT_DIR}/${archive_name}"

echo "==> publish: bundling ${#pkg_names[@]} package(s) into ${out}"
printf '     - %s\n' "${pkg_names[@]}"
tar -czf "${out}" -C "${PACKAGES_DIR}" "${pkg_names[@]}"

if command -v sha256sum >/dev/null 2>&1; then
  sha="$(sha256sum "${out}" | awk '{print $1}')"
elif command -v openssl >/dev/null 2>&1; then
  sha="$(openssl dgst -sha256 "${out}" | awk '{print $NF}')"
else
  echo "ERROR: No SHA-256 tool found (sha256sum/openssl required)"
  exit 1
fi

manifest="${ARTIFACT_DIR}/manifest.json"
{
  printf '{"build":"%s","gitSha":"%s","nsoVersion":"%s","archive":"%s","sha256":"%s","packages":[' \
    "${BUILD_ID}" "${GIT_SHA}" "${NSO_VERSION}" "${archive_name}" "${sha}"
  for i in "${!pkg_names[@]}"; do
    [[ ${i} -gt 0 ]] && printf ','
    printf '"%s"' "${pkg_names[${i}]}"
  done
  printf ']}\n'
} > "${manifest}"

ls -la "${ARTIFACT_DIR}"
echo "==> publish: manifest"
cat "${manifest}"
