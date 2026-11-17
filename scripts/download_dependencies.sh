#!/bin/bash
# Download NSO and NEDs from dl.tail-f.com, extract NEDs to packages/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_ROOT/nso-dependencies.yaml"

# Credentials: TAILF_USERNAME/TAILF_PASSWORD from Jenkins or local env
USER="${TAILF_USERNAME:-${NSO_DOWNLOAD_USER:-}}"
PASS="${TAILF_PASSWORD:-${NSO_DOWNLOAD_PASSWORD:-}}"

if [ -z "$USER" ] || [ -z "$PASS" ]; then
    echo "ERROR: Set TAILF_USERNAME/TAILF_PASSWORD or NSO_DOWNLOAD_USER/NSO_DOWNLOAD_PASSWORD"
    exit 1
fi

# Parse NSO version(s) from YAML — one or more "nso-version:" entries nested
# under each project block (config is generated per-project, one block per
# aifirstspec/inputs/*.yaml file).
mapfile -t NSO_VERSIONS < <(grep -E "^[[:space:]]+nso-version:" "$CONFIG_FILE" \
    | sed -E 's/^[[:space:]]+nso-version:[[:space:]]*"?([0-9.]+)"?.*/\1/' | sort -u)
[ "${#NSO_VERSIONS[@]}" -eq 0 ] && { echo "ERROR: No NSO version in $CONFIG_FILE"; exit 1; }

mkdir -p binaries/nso
for NSO_VERSION in "${NSO_VERSIONS[@]}"; do
    echo "==> Downloading NSO $NSO_VERSION from dl.tail-f.com"
    NSO_FILE="nso-${NSO_VERSION}.container-image-build.linux.x86_64.signed.bin"
    # If the NSO image is already loaded into the container runtime (kept
    # between builds, see NSO_CLEANUP_IMAGE), setup_nso_container.sh reuses it
    # and never reads the signed.bin — don't re-download ~730 MB for nothing.
    RUNTIME="${CONTAINER_RUNTIME:-docker}"
    if [ ! -f "binaries/nso/$NSO_FILE" ] \
       && command -v "$RUNTIME" >/dev/null 2>&1 \
       && "$RUNTIME" image inspect "cisco-nso-build:${NSO_VERSION}" >/dev/null 2>&1; then
        echo "  Image cisco-nso-build:${NSO_VERSION} already loaded — skipping $NSO_FILE download"
        continue
    fi
    if [ ! -f "binaries/nso/$NSO_FILE" ]; then
        curl -fk -u "$USER:$PASS" -o "binaries/nso/$NSO_FILE" \
            "https://dl.tail-f.com:9443/ncs/$NSO_FILE"
        echo "  Downloaded: $NSO_FILE"
    else
        echo "  Already exists: $NSO_FILE"
    fi
done

echo "==> Downloading and extracting NEDs"
mkdir -p binaries/neds packages

# Read all NED entries into an array to avoid pipe subshell issues
mapfile -t NED_LINES < <(grep -E "^\s+-\s+cisco-" "$CONFIG_FILE")

for line in "${NED_LINES[@]}"; do
    NED_NAME=$(echo "$line" | awk '{print $2}')
    NED_VER=$(echo "$line" | awk '{print $3}')
    NSO_VER=$(echo "$line" | awk '{print $4}')
    
    # Extract device type: cisco-iosxr-cli-7.61 -> cisco-iosxr
    DEVICE=$(echo "$NED_NAME" | sed -E 's/-cli-[0-9.]+$//' | sed 's/-cli$//')
    
    NED_FILE="ncs-${NSO_VER}-${DEVICE}-${NED_VER}.signed.bin"
    echo "  NED: $NED_NAME ($NED_FILE)"
    
    # Download if not exists
    if [ ! -f "binaries/neds/$NED_FILE" ]; then
        curl -fk -u "$USER:$PASS" -o "binaries/neds/$NED_FILE" \
            "https://dl.tail-f.com:9443/ncs-pkgs/${DEVICE}/${NSO_VER}/${NED_FILE}"
        echo "    Downloaded"
    else
        echo "    Already downloaded"
    fi
    
    # Extract NED to packages/
    # Check if already extracted by looking for package-meta-data.xml
    PKG_FOUND=$(find packages -maxdepth 2 -name "package-meta-data.xml" -path "*${DEVICE}*" 2>/dev/null | head -1)
    
    if [ -z "$PKG_FOUND" ]; then
        echo "    Extracting to packages/"
        
        # Make signed.bin executable and run it in packages/ directory
        chmod +x "binaries/neds/$NED_FILE"
        if (cd packages && bash "../binaries/neds/$NED_FILE" --skip-verification 2>&1); then
            echo "    Unpacked signed.bin"
        elif (cd packages && bash "../binaries/neds/$NED_FILE" 2>&1); then
            echo "    Unpacked signed.bin"
        else
            echo "    Error: Extraction failed for $NED_FILE"
            continue
        fi
        
        # Extract any tar.gz files created by the signed.bin
        TAR_FILES=$(find packages -maxdepth 1 -name "*.tar.gz" -type f)
        if [ -n "$TAR_FILES" ]; then
            echo "$TAR_FILES" | while read tarfile; do
                echo "    Extracting $(basename "$tarfile")"
                tar -xzf "$tarfile" -C packages/
                rm -f "$tarfile" packages/*.signature packages/*.py3 packages/*.cer packages/README.signature
            done
        fi
        
        # Verify extraction
        PKG_DIR=$(find packages -maxdepth 1 -type d -name "*${DEVICE}*" ! -name "packages" | head -1)
        if [ -n "$PKG_DIR" ]; then
            echo "    ✓ Extracted: $(basename "$PKG_DIR")"
        else
            echo "    Warning: Package directory not found for ${DEVICE}"
        fi
    else
        PKG_DIR=$(dirname "$PKG_FOUND")
        echo "    Already extracted: $PKG_DIR"
    fi
done

echo "==> Done"
