---
name: af-nso-install-ned
description: 'Cisco NSO NED install and removal. Use for: install NED, add NED, remove NED, install iosxr, install ios-xr, install cisco NED, install nx, install nexus, install asa, NED package, ned signed bin, packages reload, run install_ned.sh, run fetch_ned.sh. Resolves NED bundles from the shared system store (fetch_ned.sh reuses or downloads). Covers: signed.bin extraction, neds directory, runtime symlink, packages reload ordering, auto-download from dl.tail-f.com.'
argument-hint: 'NED type — e.g. "install iosxr NED", "add IOS XR", "remove cisco-iosxr"'
license: Proprietary
---

# NSO NED Install / Removal

Handles installing and removing Cisco NED packages. NEDs are installed once; for netsim devices after NED install see the `nso-devices` skill.

## Resolve the NED — Do This First

NED bundles live in the **shared system store**
(`~/.local/share/aifirst/binaries/neds/`, overridable via `AIFIRST_HOME` or
`AIFIRST_BINARIES_DIR`) — shared across all projects, never in the project tree.
You don't inspect a project folder: `fetch_ned.sh` resolves the request against
the system store and **reuses an existing bundle or downloads it**, printing the
absolute path.

Map the user's request to a vendor slug:

| User asks for | Match pattern in filename | Vendor slug for fetch_ned.sh |
|---|---|---|
| iosxr, ios xr, IOS-XR, cisco iosxr, xr | `iosxr` | `cisco-iosxr` |
| ios, ios-cli, IOS (not XR) | `ios-cli` or `ios-` (exclude `iosxr`) | `cisco-ios` |
| nx, nexus, nxos | `nx-cli` or `nxos` | `cisco-nx` |
| iosxe, ios-xe, IOS XE | `iosxe` | `cisco-iosxe` |
| asa, cisco asa | `asa-cli` | `cisco-asa-cli` |
| junos, juniper | `junos` | `juniper-junos` |
| arista, arista dcs, eos | `arista` | `arista-dcs` |

Then resolve it (reuses a cached bundle, or downloads if absent):

```bash
NED_PATH="$(scripts/fetch_ned.sh cisco-iosxr)"   # prints the absolute bundle path
```

- **Specific version** → pass it: `scripts/fetch_ned.sh cisco-iosxr 7.76`.
- Credentials, options, and the full flow are in **Auto-Download** below.

---

## Auto-Download

`fetch_ned.sh` resolves a NED from the shared system store, downloading it from `dl.tail-f.com` if it isn't already there.

### Credential Setup (first run only)

On first download you will be prompted for your Tail-F username and password. On macOS these are stored securely in the macOS Keychain (`dl.tail-f.com`) and are never written to disk, environment variables, or any project file. On Linux you are prompted every time (no persistent storage).

```bash
# First run — you will be prompted for credentials (macOS stores them in Keychain)
scripts/fetch_ned.sh cisco-iosxr
```

### Usage

```bash
# Download latest version of a NED (auto-detects NSO version)
scripts/fetch_ned.sh <vendor-slug> [version]

# Examples
scripts/fetch_ned.sh cisco-iosxr
scripts/fetch_ned.sh cisco-iosxr 7.76
scripts/fetch_ned.sh cisco-iosxr 7.76.3 --nso-version 6.7

# List all available vendors
scripts/fetch_ned.sh --list-vendors
```

### Resolve + install flow

```bash
# One step: install_ned.sh resolves the vendor slug from the shared store
# (reuses it, or downloads via fetch_ned.sh), then installs it
scripts/install_ned.sh cisco-iosxr --reload-packages

# Or two steps, when you want the resolved path first
NED_PATH=$(scripts/fetch_ned.sh cisco-iosxr)   # reuses the store, downloads if absent
scripts/install_ned.sh "$NED_PATH" --reload-packages
```

### What fetch_ned.sh does
1. Retrieves credentials from macOS Keychain (prompts on first run)
2. Maintains a single artifact manifest in `~/.cache/aifirst/ned-catalog/manifest.txt`, derived from the server's `/dir.txt` and refreshed at most once per day (1-day TTL). A `vendors.json` narrowing index is regenerated from the manifest on every refresh (real vendor slugs only; pseudo-vendors like `HEAD`, `nso-util`, `cco-logs` are excluded).
3. Resolves the vendor slug (exact match against `vendors.json`) and NED version (accepts partial version like `7.76`) by filtering the manifest
4. Checks the shared system store (`~/.local/share/aifirst/binaries/neds/`) for an existing local copy — exits immediately if found, so every project reuses it
5. Downloads from `https://dl.tail-f.com:9443/ncs-pkgs/<vendor>/<nso-ver>/`
6. Verifies SHA-512 checksum before moving into the system store
7. Prints the absolute path as the last stdout line for chaining into `install_ned.sh`

> NSO installer downloads use the same manifest: `fetch_ned.sh --nso-installer [nso-version]` resolves the correct `nso-<ver>.<os>.<arch>.installer.bin` for this host (arch normalized) and downloads it into the system store (`~/.local/share/aifirst/binaries/nso/`). The `af-nso-local-install` skill calls this automatically.

---

## Install a NED

```bash
scripts/install_ned.sh "$NED_PATH" \
  --reload-packages
```

`--reload-packages` is almost always the right choice when NSO is running — it avoids a restart.

### All options

| Option | What it does |
|---|---|
| `--reload-packages` | Run `packages reload` in NSO CLI after symlinking |
| `--install-dir PATH` | Override auto-detected `~/nso-<version>` |
| `--runtime-dir PATH` | Override auto-detected `~/nso-run-<version>` |

### What the script does (step by step)
1. Auto-detects `~/nso-[0-9]*` (install) and `~/nso-run-*` (runtime) dirs
2. Sources `ncsrc` with `set +u` / `set -u` guard
3. Extracts `signed.bin` in `mktemp -d` — cert files stay out of the system store
4. `tar -zxf <tarball> -C ~/nso-6.7/packages/neds/` — installs NED package
5. Creates `~/nso-run-6.7/packages/<ned-name>` → symlink to install dir (update-safe)
6. If `--reload-packages`: runs `packages reload` in NSO CLI

---

## Remove a NED from the Runtime

Removes from active runtime but keeps it in the install dir (can re-symlink later):

```bash
rm ~/nso-run-6.7/packages/cisco-iosxr-cli-7.76
```

Then in NSO CLI:
```
admin@ncs# packages reload
```

To fully delete the NED from disk:
```bash
rm -rf ~/nso-6.7/packages/neds/cisco-iosxr-cli-7.76
```

---

## Key Facts

### Order matters — packages reload before device XML load
If creating netsim devices after installing:
1. `install_ned.sh --reload-packages` ← must come first
2. `netsim_devices.sh --create --load-into-nso` ← uses `ncs_load` which requires NED to be loaded

Skipping `packages reload` before `ncs_load` causes:
```
Error: "cisco-iosxr-cli-7.76" is not a valid value for ned-id
```

### Symlink approach
NED binary lives in `~/nso-6.7/packages/neds/` (install dir). Runtime has a symlink in `packages/`. This means one NED can be shared across multiple runtime instances without duplication.

### Prefix derivation (used by netsim)
| NED name contains | Device prefix |
|---|---|
| `iosxr` | `xr` |
| `ios-cli` | `ios` |
| `nx-cli` | `nx` |
| `asa-cli` | `asa` |

---

## Reference Docs
- [references/install-ned.md](./references/install-ned.md) — full manual NED install walkthrough
- [references/SCRIPTS.md](./references/SCRIPTS.md) — internal script mechanics
