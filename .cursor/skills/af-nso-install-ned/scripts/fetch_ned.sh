#!/usr/bin/env bash
# fetch_ned.sh — Download Tail-F NED and NSO installer binaries from dl.tail-f.com
#
# Usage:
#   fetch_ned.sh <vendor-slug> [version] [OPTIONS]      # download a NED
#   fetch_ned.sh --nso-installer [nso-version] [OPTIONS] # download the NSO installer
#   fetch_ned.sh --list-vendors [OPTIONS]                # list vendors
#
# Options:
#   --list-vendors         List all available vendors and exit
#   --nso-installer        Resolve/download the NSO installer for this host
#   --nso-version <ver>    Override auto-detected NSO version (NED downloads)
#   -h, --help             Show this help
#
# On success the LAST stdout line is the absolute path of the downloaded file.
# All diagnostic output goes to stderr.
#
# Catalog model:
#   A single artifact manifest (<cache>/aifirst/ned-catalog/manifest.txt) is
#   derived from the server's /dir.txt, refreshed at most once per day. A derived
#   vendors.json narrows vendor resolution to exact slugs. All vendor/version/
#   file lookups are local text filters over the manifest.
#
# Credentials are stored in macOS Keychain (never written to disk or env).

set -euo pipefail

# ---------------------------------------------------------------------------
# Storage locations (system-level, shared across projects, XDG-compliant)
# ---------------------------------------------------------------------------
# Downloaded bundles (NSO installers, NED/MCP .signed.bin) live at user level so
# every project reuses them instead of re-downloading; the derived catalog is a
# cache. Resolution precedence:
#   AIFIRST_BINARIES_DIR   pin bundle downloads to one dir (CI / air-gapped)
#   AIFIRST_HOME           -> $AIFIRST_HOME/{binaries,cache}
#   XDG_DATA_HOME / XDG_CACHE_HOME
#   ~/.local/share , ~/.cache   (OS default)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_xdg_home() {
  local value="$1" fallback="$2" name="$3"
  if [[ -z "$value" ]]; then
    printf '%s\n' "$fallback"
  elif [[ "$value" == /* ]]; then
    printf '%s\n' "$value"
  else
    printf '[fetch_ned] WARNING: Ignoring relative %s=%s\n' "$name" "$value" >&2
    printf '%s\n' "$fallback"
  fi
}

if [[ -n "${AIFIRST_HOME:-}" ]]; then
  _AF_DATA_ROOT="$AIFIRST_HOME/binaries"
  CACHE_DIR="$AIFIRST_HOME/cache"
else
  _AF_DATA_HOME="$(resolve_xdg_home "${XDG_DATA_HOME:-}" "$HOME/.local/share" XDG_DATA_HOME)"
  _AF_CACHE_HOME="$(resolve_xdg_home "${XDG_CACHE_HOME:-}" "$HOME/.cache" XDG_CACHE_HOME)"
  _AF_DATA_ROOT="$_AF_DATA_HOME/aifirst/binaries"
  CACHE_DIR="$_AF_CACHE_HOME/aifirst"
fi
# AIFIRST_BINARIES_DIR pins bundle downloads to one directory (CI / air-gapped).
DATA_DIR="${AIFIRST_BINARIES_DIR:-$_AF_DATA_ROOT}"

CATALOG_DIR="$CACHE_DIR/ned-catalog"
NEDS_DIR="$DATA_DIR/neds"
NSO_DIR="$DATA_DIR/nso"

ROOT_URL="https://dl.tail-f.com:9443"
MANIFEST_URL="$ROOT_URL/dir.txt"
BASE_URL="$ROOT_URL/ncs-pkgs"

MANIFEST_FILE="$CATALOG_DIR/manifest.txt"
VENDORS_FILE="$CATALOG_DIR/vendors.json"
MANIFEST_TTL_DAYS=1

# Directories under /ncs-pkgs/ that carry artifacts but are not device NEDs.
VENDOR_DENYLIST="HEAD nso-util tmp_faultypkgsignedbin data-center pkg_release_lists cco-logs"

# ---------------------------------------------------------------------------
# Logging helpers (all go to stderr)
# ---------------------------------------------------------------------------
log()  { printf '[fetch_ned] %s\n' "$*" >&2; }
warn() { printf '[fetch_ned] WARNING: %s\n' "$*" >&2; }
die()  { printf '[fetch_ned] ERROR: %s\n' "$*" >&2; exit 1; }

ensure_private_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    chmod 0700 "$dir"
  fi
}

# Escape regex metacharacters so version/slug values are matched literally.
re_escape() { printf '%s' "$1" | sed 's/[.[\*^$()+?{|]/\\&/g'; }

# ---------------------------------------------------------------------------
# Temp file cleanup
# ---------------------------------------------------------------------------
CLEANUP_FILES=()
cleanup() {
  for f in "${CLEANUP_FILES[@]:-}"; do
    [[ -f "$f" ]] && rm -f "$f"
  done
  # Never let the loop's final test status become the script exit code (the EXIT
  # trap runs last); an empty/again-missing entry would otherwise force exit 1.
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Group 2: Credential Management
# ---------------------------------------------------------------------------

# 2.1 detect_os — prints "macos" or "linux"
detect_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    *)      echo "linux" ;;
  esac
}

# 2.2 ensure_creds — check/store credentials
# Sets TF_USER and TF_PASS in the calling scope (local variables NOT exported)
ensure_creds() {
  local os
  os="$(detect_os)"

  if [[ "$os" == "macos" ]]; then
    if security find-internet-password -s "dl.tail-f.com" &>/dev/null; then
      log "Tail-F credentials found in Keychain."
      return 0
    fi
    log "No Tail-F credentials in Keychain. Prompting for first-time setup."
    local u p
    printf 'Tail-F username: ' >&2
    read -r u </dev/tty
    printf 'Tail-F password: ' >&2
    read -rs p </dev/tty
    printf '\n' >&2
    security add-internet-password \
      -s "dl.tail-f.com" \
      -a "$u" \
      -w "$p" \
      -l "Tail-F NED Downloads" 2>/dev/null \
      || die "Failed to store credentials in Keychain"
    log "Credentials saved to Keychain."
  else
    # Linux — always prompt, never store
    log "Linux detected — credentials will not be stored."
    printf 'Tail-F username: ' >&2
    read -r TF_USER </dev/tty
    printf 'Tail-F password: ' >&2
    read -rs TF_PASS </dev/tty
    printf '\n' >&2
    export TF_USER TF_PASS
  fi
}

# 2.3 get_creds — populate TF_USER / TF_PASS from Keychain or prompts
get_creds() {
  local os
  os="$(detect_os)"

  if [[ "$os" == "macos" ]]; then
    TF_USER="$(security find-internet-password -s "dl.tail-f.com" 2>/dev/null \
      | awk -F'"' '/"acct"/{print $4}')"
    TF_PASS="$(security find-internet-password -s "dl.tail-f.com" -w 2>/dev/null)"
    if [[ -z "$TF_USER" || -z "$TF_PASS" ]]; then
      die "Could not retrieve credentials from Keychain. Run ensure_creds first."
    fi
  else
    # Linux: TF_USER/TF_PASS should already be set by ensure_creds
    if [[ -z "${TF_USER:-}" || -z "${TF_PASS:-}" ]]; then
      ensure_creds
    fi
  fi
}

# 2.4 handle_401 — delete stale creds, re-prompt, return 0 if new creds, 1 on second failure
handle_401() {
  local os
  os="$(detect_os)"
  warn "Authentication failed (HTTP 401)."

  if [[ "$os" == "macos" ]]; then
    log "Removing stale Keychain entry for dl.tail-f.com ..."
    security delete-internet-password -s "dl.tail-f.com" 2>/dev/null || true
    # Unset module-level vars so ensure_creds/get_creds repopulate them
    TF_USER=""
    TF_PASS=""
  else
    TF_USER=""
    TF_PASS=""
  fi

  log "Please re-enter your Tail-F credentials."
  ensure_creds
  get_creds
  # Caller checks return value; we return 0 to indicate new creds were obtained
  return 0
}

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

# Authenticated curl that returns HTTP status via global _LAST_HTTP_STATUS
_curl_auth_status() {
  local url="$1" out_file="$2"
  _LAST_HTTP_STATUS="$(curl --silent --show-error \
    --basic -u "${TF_USER}:${TF_PASS}" \
    --write-out "%{http_code}" \
    -o "$out_file" \
    "$url" 2>/dev/null)" || true
}
_LAST_HTTP_STATUS=""

# Die with VPN hint when HTTP 000 (DNS/connection failure)
_die_http() {
  local status="$1" msg="$2"
  if [[ "$status" == "000" || -z "$status" ]]; then
    die "$msg (HTTP 000) — could not reach dl.tail-f.com; are you connected to VPN?"
  else
    die "$msg (HTTP $status)"
  fi
}

# ---------------------------------------------------------------------------
# Group 3: Manifest Cache
# ---------------------------------------------------------------------------

# 3.1 ensure_catalog_dir
ensure_catalog_dir() {
  ensure_private_dir "$CATALOG_DIR"
  ensure_private_dir "$NEDS_DIR"
}

# 3.2 is_stale(file, ttl_days) — returns 0 (true) if missing or older than TTL
is_stale() {
  local file="$1" ttl_days="$2"
  [[ ! -f "$file" ]] && return 0
  # find prints the file only when it is older than ttl_days
  local old
  old="$(find "$file" -mtime +"$ttl_days" 2>/dev/null || true)"
  [[ -n "$old" ]] && return 0
  return 1
}

# 3.3 fetch_manifest — download /dir.txt, filter to real artifacts, cache, derive vendors
fetch_manifest() {
  log "Refreshing artifact manifest from $MANIFEST_URL ..."
  ensure_creds
  get_creds

  local tmp
  tmp="$(mktemp "$CATALOG_DIR/.manifest_XXXXXX")"
  CLEANUP_FILES+=("$tmp")

  _curl_auth_status "$MANIFEST_URL" "$tmp"
  if [[ "$_LAST_HTTP_STATUS" == "401" ]]; then
    handle_401
    _curl_auth_status "$MANIFEST_URL" "$tmp"
    [[ "$_LAST_HTTP_STATUS" != "200" ]] && _die_http "$_LAST_HTTP_STATUS" "Authentication failed fetching manifest"
  fi
  [[ "$_LAST_HTTP_STATUS" != "200" ]] && _die_http "$_LAST_HTTP_STATUS" "Failed to fetch manifest"

  # Keep only downloadable package artifacts; drop logs, checksums, and withdrawn packages.
  local filtered="${MANIFEST_FILE}.tmp"
  grep -E '\.(signed\.bin|tar\.gz|tgz|installer\.bin)$' "$tmp" 2>/dev/null \
    | grep -v -- '-Withdrawn' \
    > "$filtered" || true

  if [[ ! -s "$filtered" ]]; then
    rm -f "$filtered" "$tmp"
    die "Manifest download produced no artifact entries — server format may have changed."
  fi

  mv -f "$filtered" "$MANIFEST_FILE"
  rm -f "$tmp"

  local n
  n="$(wc -l < "$MANIFEST_FILE" | tr -d ' ')"
  log "Manifest cached: $n artifact entries."

  derive_vendors
  cleanup_legacy_cache
}

# 3.4 derive_vendors — build vendors.json from the manifest (minus pseudo-vendor denylist)
derive_vendors() {
  [[ -f "$MANIFEST_FILE" ]] || die "derive_vendors called before manifest exists."

  local vendors
  vendors="$(awk -F/ '$2=="ncs-pkgs" && ($0 ~ /\.(signed\.bin|tar\.gz|tgz)$/){print $3}' \
    "$MANIFEST_FILE" | sort -u)"

  local json="[\n"
  local first=1 v
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    case " $VENDOR_DENYLIST " in *" $v "*) continue ;; esac
    if [[ $first -eq 1 ]]; then
      json+="  \"$v\""
      first=0
    else
      json+=",\n  \"$v\""
    fi
  done <<< "$vendors"
  json+="\n]"

  printf '%b\n' "$json" > "$VENDORS_FILE"
  log "Derived $(grep -c '"' "$VENDORS_FILE" 2>/dev/null || echo '?') vendors to $VENDORS_FILE"
}

# 3.5 cleanup_legacy_cache — remove obsolete scraped per-vendor JSON tiers
# (both <vendor>.json and <vendor>-nso<ver>.json from the old three-tier catalog);
# keep only the manifest-derived vendors.json narrowing index and manifest.txt.
cleanup_legacy_cache() {
  find "$CATALOG_DIR" -maxdepth 1 -type f -name '*.json' ! -name 'vendors.json' -delete 2>/dev/null || true
  # Stale raw dir.txt from an earlier iteration — the cache is manifest.txt now.
  rm -f "$CATALOG_DIR/dir.txt" 2>/dev/null || true
}

# 3.6 ensure_manifest — refresh the manifest if stale, ensure vendors.json exists
ensure_manifest() {
  if is_stale "$MANIFEST_FILE" "$MANIFEST_TTL_DAYS"; then
    fetch_manifest
  elif [[ ! -f "$VENDORS_FILE" ]]; then
    derive_vendors
  fi
}

# 3.7 resolve_vendor(slug) — return canonical slug from vendors.json or exit with list
resolve_vendor() {
  local slug="$1"
  ensure_manifest

  # Exact match
  if grep -q "\"$slug\"" "$VENDORS_FILE" 2>/dev/null; then
    echo "$slug"
    return 0
  fi

  # Case-insensitive substring match
  local match
  match="$(grep -oE '"[^"]+"' "$VENDORS_FILE" 2>/dev/null | tr -d '"' \
    | grep -i "$slug" | head -1 || true)"
  if [[ -n "$match" ]]; then
    log "Resolved '$slug' → '$match'"
    echo "$match"
    return 0
  fi

  # Force a refresh once, then retry exact match
  fetch_manifest
  if grep -q "\"$slug\"" "$VENDORS_FILE" 2>/dev/null; then
    echo "$slug"
    return 0
  fi

  log "Vendor '$slug' not found. Available vendors:"
  grep -oE '"[^"]+"' "$VENDORS_FILE" 2>/dev/null | tr -d '"' | while read -r v; do
    printf '  %s\n' "$v" >&2
  done
  die "Vendor '$slug' not found. See list above."
}

# 3.8 available_nso_versions(vendor) — NSO-version directories present for a vendor
available_nso_versions() {
  local vendor="$1" re
  re="$(re_escape "$vendor")"
  grep -E "^\./ncs-pkgs/${re}/" "$MANIFEST_FILE" 2>/dev/null \
    | awk -F/ '{print $4}' | sort -Vu
}

# 3.9 resolve_version(vendor, partial_ned_ver, nso_ver) — resolve NED version from manifest
resolve_version() {
  local vendor="$1" partial="${2:-}" nso_ver="${3:-}"

  # Verify the NSO-version directory exists for this vendor
  if ! available_nso_versions "$vendor" | grep -qx "$nso_ver"; then
    log "NSO $nso_ver not found for $vendor. Available NSO versions:"
    available_nso_versions "$vendor" | while read -r d; do printf '  %s\n' "$d" >&2; done
    die "No $vendor packages available for NSO $nso_ver. See list above or use --nso-version."
  fi

  local vre nre
  vre="$(re_escape "$vendor")"
  nre="$(re_escape "$nso_ver")"

  local all_versions
  all_versions="$(grep -E "^\./ncs-pkgs/${vre}/${nre}/ncs-${nre}-${vre}-" "$MANIFEST_FILE" 2>/dev/null \
    | sed -E "s#^\./ncs-pkgs/${vre}/${nre}/ncs-${nre}-${vre}-##" \
    | sed -E 's/\.(signed\.bin|tar\.gz|tgz)$//' \
    | sort -Vu || true)"

  if [[ -z "$all_versions" ]]; then
    die "No NED versions found for $vendor with NSO $nso_ver"
  fi

  if [[ -z "$partial" ]]; then
    local latest
    latest="$(echo "$all_versions" | sort -V | tail -1)"
    log "Using latest NED version: $latest"
    echo "$latest"
    return 0
  fi

  # Exact match
  if echo "$all_versions" | grep -qx "$partial"; then
    echo "$partial"
    return 0
  fi

  # Prefix match (e.g. "7.76" matches "7.76.3")
  local match
  match="$(echo "$all_versions" \
    | grep "^$(re_escape "$partial")\." \
    | sort -V | tail -1 || true)"
  if [[ -n "$match" ]]; then
    log "Resolved NED version '$partial' → '$match'"
    echo "$match"
    return 0
  fi

  log "NED version '$partial' not found for $vendor (NSO $nso_ver). Available versions:"
  echo "$all_versions" | sort -V | while read -r v; do printf '  %s\n' "$v" >&2; done
  die "NED version '$partial' not found for vendor '$vendor' with NSO $nso_ver."
}

# ---------------------------------------------------------------------------
# Group 4: Download and Verification
# ---------------------------------------------------------------------------

# 4.1 check_local(vendor, version) — return path if already downloaded
check_local() {
  local vendor="$1" version="$2"
  local found
  found="$(find "$NEDS_DIR" -maxdepth 1 \
    -name "ncs-*-${vendor}-${version}.*" \
    ! -name "*.sha512" \
    2>/dev/null | head -1)"
  echo "${found:-}"
}

# 4.2 detect_nso_version
detect_nso_version() {
  local install_dir
  install_dir="$(ls -d "$HOME"/nso-[0-9]* 2>/dev/null | sort -V | tail -1)"
  if [[ -z "$install_dir" ]]; then
    die "No NSO installation found at ~/nso-[0-9]*. Use --nso-version to specify."
  fi
  basename "$install_dir" | sed 's/nso-//'
}

# 4.3 resolve_filename(vendor, ned_version, nso_ver) — return manifest-relative path
# Prefers .signed.bin over archive types. Output has no leading "./".
resolve_filename() {
  local vendor="$1" version="$2" nso_ver="$3"
  local vre nre vver
  vre="$(re_escape "$vendor")"
  nre="$(re_escape "$nso_ver")"
  vver="$(re_escape "$version")"

  local prefix="^\./ncs-pkgs/${vre}/${nre}/ncs-${nre}-${vre}-${vver}"

  local line
  line="$(grep -E "${prefix}\.signed\.bin$" "$MANIFEST_FILE" 2>/dev/null | head -1 || true)"
  if [[ -z "$line" ]]; then
    line="$(grep -E "${prefix}\.(tar\.gz|tgz)$" "$MANIFEST_FILE" 2>/dev/null | head -1 || true)"
  fi

  if [[ -z "$line" ]]; then
    log "No file found for NSO $nso_ver / $vendor $version. Available files:"
    grep -E "^\./ncs-pkgs/${vre}/${nre}/" "$MANIFEST_FILE" 2>/dev/null | while read -r f; do
      printf '  %s\n' "${f#./}" >&2
    done
    die "No matching NED file. Try --nso-version with a different NSO version."
  fi

  echo "${line#./}"
}

# 4.4 download_file(url, dest_tmp) — download with Basic Auth, handle 401
download_file() {
  local url="$1" dest_tmp="$2"
  log "Downloading: $url"

  local http_status
  http_status="$(curl --silent --show-error \
    --basic -u "${TF_USER}:${TF_PASS}" \
    --progress-bar \
    --write-out "%{http_code}" \
    -o "$dest_tmp" \
    "$url" 2>&1 | tail -1)" || true

  if [[ "$http_status" == "401" ]]; then
    rm -f "$dest_tmp"
    handle_401
    http_status="$(curl --silent --show-error \
      --basic -u "${TF_USER}:${TF_PASS}" \
      --progress-bar \
      --write-out "%{http_code}" \
      -o "$dest_tmp" \
      "$url" 2>&1 | tail -1)" || true
    if [[ "$http_status" == "401" ]]; then
      rm -f "$dest_tmp"
      die "Authentication failed on retry. Check your Tail-F credentials."
    fi
  fi

  if [[ "$http_status" != "200" ]]; then
    rm -f "$dest_tmp"
    die "Download failed (HTTP $http_status): $url"
  fi

  log "Download complete."
}

# 4.5 verify_sha512(file, sha_url) — verify against companion .sha512 if present
verify_sha512() {
  local file="$1" sha_url="$2"
  log "Verifying SHA-512 checksum ..."

  local sha_tmp
  sha_tmp="$(mktemp "$CATALOG_DIR/.sha512_XXXXXX")"
  CLEANUP_FILES+=("$sha_tmp")

  local http_status
  http_status="$(curl --silent --show-error \
    --basic -u "${TF_USER}:${TF_PASS}" \
    --write-out "%{http_code}" \
    -o "$sha_tmp" \
    "$sha_url" 2>/dev/null)" || true

  if [[ "$http_status" == "404" ]]; then
    rm -f "$sha_tmp"
    log "No .sha512 companion file on server — skipping checksum (signature is embedded in .signed.bin)."
    return 0
  fi

  if [[ "$http_status" != "200" ]]; then
    rm -f "$sha_tmp"
    die "Failed to download checksum file (HTTP $http_status): $sha_url"
  fi

  local file_dir file_base
  file_dir="$(dirname "$file")"
  file_base="$(basename "$file")"

  local sha_content
  sha_content="$(cat "$sha_tmp")"
  printf '%s' "$sha_content" | awk -v base="$file_base" '{print $1 "  " base}' > "$sha_tmp"

  if ! (cd "$file_dir" && shasum -a 512 -c "$sha_tmp" >/dev/null 2>&1); then
    warn "SHA-512 checksum mismatch! Deleting downloaded file."
    rm -f "$file"
    rm -f "$sha_tmp"
    die "Checksum verification failed for $file_base"
  fi

  rm -f "$sha_tmp"
  log "Checksum verified OK."
}

# ---------------------------------------------------------------------------
# Group 6: NSO Installer Resolution
# ---------------------------------------------------------------------------

# 6.1 detect_host_os — prints "darwin" or "linux"
detect_host_os() {
  case "$(uname -s)" in
    Darwin) echo "darwin" ;;
    Linux)  echo "linux" ;;
    *)      die "Unsupported host OS: $(uname -s)" ;;
  esac
}

# 6.2 detect_host_arch — prints normalized "arm64" or "x86_64"
detect_host_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo "arm64" ;;
    x86_64|amd64)  echo "x86_64" ;;
    *)             die "Unsupported host architecture: $(uname -m)" ;;
  esac
}

# 6.3 resolve_nso_installer(version) — return manifest-relative installer path for this host
resolve_nso_installer() {
  local want_ver="${1:-}"
  local os arch
  os="$(detect_host_os)"
  arch="$(detect_host_arch)"
  log "Host: os=$os arch=$arch"

  # Top-level installer lines only: ./ncs/nso-<ver>.<os>.<arch>.installer.bin
  local matches
  matches="$(grep -E "^\./ncs/nso-[0-9][0-9.]*\.${os}\.${arch}\.installer\.bin$" "$MANIFEST_FILE" 2>/dev/null \
    | grep -v -- '-Withdrawn' || true)"

  if [[ -z "$matches" ]]; then
    die "No NSO installer found for host os=$os arch=$arch in the manifest."
  fi

  local versions
  versions="$(echo "$matches" \
    | sed -E "s#^\./ncs/nso-##; s#\.${os}\.${arch}\.installer\.bin\$##" \
    | sort -Vu)"

  local chosen
  if [[ -z "$want_ver" ]]; then
    chosen="$(echo "$versions" | tail -1)"
    log "Using latest NSO version: $chosen"
  elif echo "$versions" | grep -qx "$want_ver"; then
    chosen="$want_ver"
  else
    # Prefix match (e.g. 6.6 -> 6.6.4)
    chosen="$(echo "$versions" | grep "^$(re_escape "$want_ver")\." | sort -V | tail -1 || true)"
    if [[ -z "$chosen" ]]; then
      log "NSO version '$want_ver' not available for $os/$arch. Available:"
      echo "$versions" | while read -r v; do printf '  %s\n' "$v" >&2; done
      die "NSO version '$want_ver' not found for this host."
    fi
    log "Resolved NSO version '$want_ver' → '$chosen'"
  fi

  local cre
  cre="$(re_escape "$chosen")"
  local line
  line="$(echo "$matches" | grep -E "^\./ncs/nso-${cre}\.${os}\.${arch}\.installer\.bin$" | head -1)"
  [[ -z "$line" ]] && die "Failed to resolve installer path for NSO $chosen ($os/$arch)."
  echo "${line#./}"
}

# 6.4 fetch_nso_installer(version) — resolve + download NSO installer, print absolute path
fetch_nso_installer() {
  local want_ver="${1:-}"
  ensure_private_dir "$NSO_DIR"
  ensure_manifest

  local relpath filename dest_path
  relpath="$(resolve_nso_installer "$want_ver")"
  filename="$(basename "$relpath")"
  dest_path="$NSO_DIR/$filename"
  log "Target installer: $filename"

  if [[ -f "$dest_path" ]]; then
    log "Installer already present: $dest_path"
    echo "$(cd "$(dirname "$dest_path")" && pwd)/$(basename "$dest_path")"
    return 0
  fi

  local url="$ROOT_URL/$relpath"
  local sha_url="${url}.sha512"

  ensure_creds
  get_creds

  local dest_tmp
  dest_tmp="$(mktemp "$NSO_DIR/.download_XXXXXX")"
  CLEANUP_FILES+=("$dest_tmp")

  download_file "$url" "$dest_tmp"
  verify_sha512 "$dest_tmp" "$sha_url"

  mv "$dest_tmp" "$dest_path"
  CLEANUP_FILES=("${CLEANUP_FILES[@]/$dest_tmp/}")
  log "Saved: $dest_path"

  echo "$(cd "$(dirname "$dest_path")" && pwd)/$(basename "$dest_path")"
}

# ---------------------------------------------------------------------------
# Group 5: Main Entrypoint
# ---------------------------------------------------------------------------

usage() {
  cat >&2 <<EOF
Usage:
  fetch_ned.sh <vendor-slug> [version] [OPTIONS]        Download a NED
  fetch_ned.sh --nso-installer [nso-version] [OPTIONS]  Download the NSO installer
  fetch_ned.sh --list-vendors [OPTIONS]                 List vendors

Arguments:
  vendor-slug   NED vendor slug (e.g. cisco-iosxr, cisco-ios, cisco-nx)
  version       NED version or prefix (e.g. 7.76 or 7.76.3). Defaults to latest.

Options:
  --list-vendors         List all available vendor slugs and exit
  --nso-installer        Resolve/download the NSO installer for this host
  --nso-version <ver>    Override auto-detected NSO version (NED downloads)
  -h, --help             Show this help

Examples:
  fetch_ned.sh cisco-iosxr
  fetch_ned.sh cisco-iosxr 7.76
  fetch_ned.sh cisco-iosxr 7.76.3 --nso-version 6.7
  fetch_ned.sh --list-vendors
  fetch_ned.sh --nso-installer
  fetch_ned.sh --nso-installer 6.7
EOF
}

# 5.1 Parse CLI arguments
VENDOR_SLUG=""
VERSION_ARG=""
LIST_VENDORS=0
NSO_INSTALLER=0
NSO_VER_OVERRIDE=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list-vendors)
        LIST_VENDORS=1
        shift
        ;;
      --nso-installer)
        NSO_INSTALLER=1
        shift
        ;;
      --nso-version)
        [[ $# -lt 2 ]] && die "--nso-version requires a value"
        NSO_VER_OVERRIDE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        if [[ -z "$VENDOR_SLUG" ]]; then
          VENDOR_SLUG="$1"
        elif [[ -z "$VERSION_ARG" ]]; then
          VERSION_ARG="$1"
        else
          die "Unexpected argument: $1"
        fi
        shift
        ;;
    esac
  done
}

# 5.2 + 5.3 Main flow
main() {
  parse_args "$@"

  ensure_catalog_dir

  # NSO installer mode — VENDOR_SLUG (if any) is treated as the NSO version.
  if [[ $NSO_INSTALLER -eq 1 ]]; then
    fetch_nso_installer "${VENDOR_SLUG:-}"
    exit 0
  fi

  # --list-vendors
  if [[ $LIST_VENDORS -eq 1 ]]; then
    ensure_manifest
    grep -oE '"[^"]+"' "$VENDORS_FILE" 2>/dev/null | tr -d '"' | while read -r v; do
      printf '%s\n' "$v"
    done
    exit 0
  fi

  if [[ -z "$VENDOR_SLUG" ]]; then
    usage
    die "vendor-slug is required."
  fi

  # Resolve vendor (refreshes manifest as needed)
  local vendor
  vendor="$(resolve_vendor "$VENDOR_SLUG")"

  # Detect NSO version (needed to navigate the manifest)
  local nso_ver
  if [[ -n "$NSO_VER_OVERRIDE" ]]; then
    nso_ver="$NSO_VER_OVERRIDE"
    log "Using NSO version override: $nso_ver"
  else
    nso_ver="$(detect_nso_version)"
    log "Detected NSO version: $nso_ver"
  fi

  # Resolve NED version
  local version
  version="$(resolve_version "$vendor" "${VERSION_ARG:-}" "$nso_ver")"
  log "Resolved: vendor=$vendor ned_version=$version nso_version=$nso_ver"

  # Check if already downloaded locally
  local local_path
  local_path="$(check_local "$vendor" "$version")"
  if [[ -n "$local_path" ]]; then
    log "Already downloaded: $local_path"
    echo "$local_path"
    exit 0
  fi

  # Resolve filename (manifest-relative path)
  local relpath filename
  relpath="$(resolve_filename "$vendor" "$version" "$nso_ver")"
  filename="$(basename "$relpath")"
  log "Target file: $filename"

  local download_url="$ROOT_URL/$relpath"
  local sha_url="${download_url}.sha512"
  local dest_path="$NEDS_DIR/$filename"

  if [[ -f "$dest_path" ]]; then
    log "File already exists: $dest_path"
    echo "$dest_path"
    exit 0
  fi

  # Populate credentials in this (parent) scope before downloading. The manifest
  # refresh ran inside a command-substitution subshell (resolve_vendor), so any
  # creds it set did not propagate here — without this, download_file references
  # unbound TF_USER/TF_PASS under `set -u`.
  ensure_creds
  get_creds

  local dest_tmp
  dest_tmp="$(mktemp "$NEDS_DIR/.download_XXXXXX")"
  CLEANUP_FILES+=("$dest_tmp")

  download_file "$download_url" "$dest_tmp"
  verify_sha512 "$dest_tmp" "$sha_url"

  mv "$dest_tmp" "$dest_path"
  CLEANUP_FILES=("${CLEANUP_FILES[@]/$dest_tmp/}")
  log "Saved: $dest_path"

  echo "$(cd "$(dirname "$dest_path")" && pwd)/$(basename "$dest_path")"
}

main "$@"
