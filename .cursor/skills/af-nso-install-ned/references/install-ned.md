# Manual NED Install

Covers how to install a Cisco NED (Network Element Driver) from a signed bundle and wire it into an NSO runtime.

For creating simulated devices after installing a NED, see [netsim-devices.md](netsim-devices.md).  
Assumes NSO is already installed and `~/nso-6.7/ncsrc` has been sourced. See [install-nso.md](install-nso.md).

---

## What is a NED?

A NED is a package that teaches NSO how to talk to a specific device type (e.g. Cisco IOS XR). It contains:
- YANG models describing the device's configuration and state
- Java code implementing the NETCONF/CLI protocol adapter

NEDs live in `~/nso-6.7/packages/neds/` and are activated per-runtime via symlinks in `~/nso-run-6.7/packages/`.

---

## Step 1 — Source the NSO environment

```bash
source ~/nso-6.7/ncsrc
export JAVA_HOME="/opt/homebrew/opt/openjdk@21"
```

---

## Step 2 — Extract the signed NED bundle

Cisco NEDs are distributed as `.signed.bin` files. Extract in a temp directory to avoid cluttering your downloads folder with cert files:

```bash
EXTRACT_DIR=$(mktemp -d)
cd "$EXTRACT_DIR"
sh ~/Downloads/ncs-6.7-cisco-iosxr-7.76.3.signed.bin
```

What this does:
1. Downloads Cisco CA certificates from `cisco.com` to verify the bundle signature.
2. Validates the cryptographic signature of the tarball inside.
3. Extracts `ncs-6.7-cisco-iosxr-7.76.3.tar.gz` into the current directory.

```bash
# Confirm the tarball was produced
ls "$EXTRACT_DIR"/*.tar.gz
# expected: ncs-6.7-cisco-iosxr-7.76.3.tar.gz
```

---

## Step 3 — Install the NED into the NSO packages directory

```bash
NEDS_DIR="$HOME/nso-6.7/packages/neds"
mkdir -p "$NEDS_DIR"

tar -zxf "$EXTRACT_DIR/ncs-6.7-cisco-iosxr-7.76.3.tar.gz" -C "$NEDS_DIR"
```

Confirm what was extracted:

```bash
ls "$NEDS_DIR"
# e.g.: cisco-iosxr-cli-7.76/

ls "$NEDS_DIR/cisco-iosxr-cli-7.76/"
# package-meta-data.xml  load-dir/  src/  ...
```

---

## Step 4 — Symlink the NED into the runtime packages directory

NSO reads packages from `~/nso-run-6.7/packages/`. Add a symlink:

```bash
NED_PKG="cisco-iosxr-cli-7.76"
NEDS_DIR="$HOME/nso-6.7/packages/neds"
RUNTIME_PKGS="$HOME/nso-run-6.7/packages"

mkdir -p "$RUNTIME_PKGS"

# Remove stale symlink if updating
rm -f "$RUNTIME_PKGS/$NED_PKG"

ln -sf "$NEDS_DIR/$NED_PKG" "$RUNTIME_PKGS/$NED_PKG"

# Verify
ls -la "$RUNTIME_PKGS/"
```

Using a symlink means the NED binary lives in one place (the install dir) and can be shared across multiple runtime instances.

---

## Step 5 — Reload NSO packages

Tell a running NSO to pick up the new package without restarting:

```
admin@ncs# packages reload
```

Expected output:

```
>>> System upgrade is starting.
>>> System upgrade has completed successfully.
reload-result {
    package cisco-iosxr-cli-7.76
    result true
}
```

> **Must be done before loading device XML.** If you skip this step and try `ncs_load` immediately, NSO will reject the device XML with `"cisco-iosxr-cli-7.76" is not a valid value` because it hasn't ingested the NED's YANG models yet.

If NSO is not running, packages are loaded automatically on next start — no manual reload needed.

---

## Removing a NED from the runtime

This removes the NED from the active runtime but keeps it in the install dir:

```bash
rm ~/nso-run-6.7/packages/cisco-iosxr-cli-7.76
```

```
admin@ncs# packages reload
```

---

## Common prefix derivations

Useful when creating netsim devices — see [netsim-devices.md](netsim-devices.md).

| NED name contains | Suggested device prefix |
|---|---|
| `iosxr` | `xr` |
| `ios-cli` | `ios` |
| `nx-cli` | `nx` |
| `asa-cli` | `asa` |
