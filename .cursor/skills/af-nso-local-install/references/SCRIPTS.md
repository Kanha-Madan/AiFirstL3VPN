# NSO Automation Scripts — Step-by-Step Reference

Three scripts cover the full lifecycle of a Cisco NSO local install on macOS.

---

## 1. `install_nso_local.sh` — Install NSO

**Purpose:** Run once to install NSO software and create a runtime instance.

```bash
# Resolve the installer from the shared store (reuse if present, else download)
./scripts/install_nso_local.sh --fetch --persist-env --start --verify

# Or point at a local installer you already have
./scripts/install_nso_local.sh ~/Downloads/nso-6.7.darwin.arm64.installer.bin \
  --persist-env --start --verify
```

### What happens, step by step

**Step 1 — Validate inputs**
- Confirms the `.installer.bin` file exists and has the right suffix.
- Rejects `.signed.bin` (must be unpacked first to get `.installer.bin`).
- Extracts the NSO version number from the filename (e.g. `nso-6.7...` → `6.7`).

**Step 2 — Resolve directories**
- `INSTALL_DIR` defaults to `$HOME/nso-<version>` (e.g. `~/nso-6.7`).
- `RUNTIME_DIR` defaults to `$HOME/nso-run-<version>` (e.g. `~/nso-run-6.7`).
- Both paths honour `--install-dir` and `--runtime-dir` overrides.

**Step 3 — Run the NSO local installer** *(skipped if `ncsrc` already exists)*
```bash
sh <installer.bin> ~/nso-6.7 --local-install
```
Installs NSO binaries, libraries, example packages, and NEDs into `~/nso-6.7`.

**Step 4 — Source `ncsrc`**
```bash
set +u
source ~/nso-6.7/ncsrc
set -u
```
Sets `PATH`, `NCS_DIR`, `PYTHONPATH`, `DYLD_LIBRARY_PATH`, etc.  
`set +u` / `set -u` wrapping prevents errors if `DYLD_LIBRARY_PATH` is unset.

**Step 5 — Create the runtime instance** *(skipped if `ncs.conf` already exists)*
```bash
ncs-setup --dest ~/nso-run-6.7
```
Creates the working directory containing `ncs.conf`, `ncs-cdb/`, `logs/`, `packages/`, `state/`.  
This is where `ncs` (the daemon) must always be started from.

**Step 6 — Patch `ncs.conf` for RESTCONF** *(only with `--enable-restconf`)*
Uses Python 3 to set `<restconf><enabled>true</enabled>` and enable the WebUI TCP transport on the chosen port (default 8080). Avoids fragile multiline `sed`.

**Step 7 — Start NSO** *(only with `--start`)*
```bash
cd ~/nso-run-6.7 && ncs
```
NSO **must** be started from `RUNTIME_DIR`. Running `ncs` from any other directory causes `Cannot access directory ./state` (exit 21).

**Step 8 — Provision admin credentials** *(whenever NSO is running)*
Sets the NSO admin password from `$NSO_ADMIN_PASSWORD`, else `<runtime>/nso-admin.env`, else a generated 24-character alphanumeric value, applied with `ncs_load` (NSO hashes it). Saves `NSO_ADMIN_USER` and `NSO_ADMIN_PASSWORD` to `<runtime>/nso-admin.env` (mode 600) and never prints the value. With `--enable-restconf` it logs in over RESTCONF and fails on 401/403. If NSO is not running the script fails instead of leaving the default in force, unless `--insecure-default-admin` is passed (throwaway development only).

**Step 9 — Persist environment** *(only with `--persist-env`)*
Appends `source "~/nso-6.7/ncsrc"` to `~/.zprofile`, `~/.zshrc`, and `~/.bash_profile` (idempotent — skips if already present). This ensures `ncs`, `ncs_cli`, `ncs-netsim`, etc. are on `PATH` in every new terminal. When the credential file exists it also appends `[ -f "<runtime>/nso-admin.env" ] && source "<runtime>/nso-admin.env"`.

**Step 10 — Verify installation** *(only with `--verify`)*
Checks: install dir exists, `ncsrc` exists, runtime dir exists, `ncs.conf` exists, `ncs` and `ncs-setup` are on `PATH`. Reports pass/fail for each check.

**Step 11 — Explore installation** *(only with `--explore`)*
Lists contents of `examples.ncs/`, `packages/neds/`, and the path to HTML docs.

**Step 12 — Enable dev mode** *(only with `--dev-mode`, requires `--start`)*
```bash
ncs_cli -u "${NSO_ADMIN_USER}" -C 'license smart development enable'
```

### Key facts
| Item | Value |
|---|---|
| Install dir | `~/nso-<version>` |
| Runtime dir | `~/nso-run-<version>` |
| ncsrc path | `~/nso-<version>/ncsrc` |
| Admin credentials | `$NSO_ADMIN_USER` (default `admin`) / `$NSO_ADMIN_PASSWORD`, generated at install and saved to `<runtime>/nso-admin.env`; `admin` / `admin` only applies when NSO was not running and `--insecure-default-admin` was passed |
| RESTCONF port | `8080` |
| NETCONF SSH port | `2022` |
| Java requirement | `JAVA_HOME` must point to openjdk@21 |

---

## 2. `install_ned.sh` — Install a NED

**Purpose:** Install a NED (Network Element Driver) from a local bundle or the shared store, wire it into the runtime, and optionally reload packages. To create simulated devices afterward, use `netsim_devices.sh`.

```bash
# From a local artifact
./scripts/install_ned.sh ~/Downloads/ncs-6.7-cisco-iosxr-7.76.3.signed.bin \
  --reload-packages

# From a vendor slug — resolved from the shared store (reused if present, else
# downloaded into it) via fetch_ned.sh, then installed in one step
./scripts/install_ned.sh cisco-iosxr 7.76.3 --reload-packages
```

### What happens, step by step

**Step 1 — Resolve the NED artifact**
If the first argument is an existing `.signed.bin`, `.tar.gz`, or `.tgz` file it is used directly. Otherwise (or with `--fetch`) it is treated as a vendor slug and resolved from the shared XDG store via `fetch_ned.sh`, which reuses an existing download or fetches one into `~/.local/share/aifirst/binaries/neds/`. Use `--nso-version <ver>` to override the auto-detected NSO version during resolution.

**Step 2 — Auto-detect NSO directories**
- Finds the newest `~/nso-[0-9]*` directory (excluding `nso-run-*`) → `INSTALL_DIR`.
- Finds the newest `~/nso-run-*` directory → `RUNTIME_DIR`.
- Both can be overridden with `--install-dir` / `--runtime-dir`.

**Step 3 — Ensure `packages/neds` exists**
```bash
mkdir -p ~/nso-6.7/packages/neds
```
The directory may not exist on a fresh install that ships no bundled NEDs.

**Step 4 — Source `ncsrc`**
Same `set +u` / `set -u` pattern as the install script. Provides `ncs-netsim`, `ncs_cli`, `ncs_load`, etc.

**Step 5 — Extract the signed bundle** *(`.signed.bin` only)*
```bash
EXTRACT_DIR=$(mktemp -d)
cd "$EXTRACT_DIR" && sh <signed.bin>
```
- Verification downloads Cisco CA certs from cisco.com and validates the cryptographic signature.
- Extraction happens in a temp dir (not `~/Downloads`) so cert files don't clutter your downloads folder.
- A `trap` ensures the temp dir is deleted on exit, even on failure.
- Finds the resulting `.tar.gz` inside the temp dir.

**Step 6 — Extract the NED tarball into `packages/neds`**
```bash
tar -zxf <ned>.tar.gz -C ~/nso-6.7/packages/neds/
```
Creates a package directory like `cisco-iosxr-cli-7.76/` containing `package-meta-data.xml`, YANG models, and compiled Java JARs.

**Step 7 — Identify the installed package directory**
Finds the newest `package-meta-data.xml` under `packages/neds/` to confirm the package name.

**Step 8 — Symlink into runtime packages**
```bash
ln -sf ~/nso-6.7/packages/neds/cisco-iosxr-cli-7.76 \
        ~/nso-run-6.7/packages/cisco-iosxr-cli-7.76
```
NSO loads packages from `RUNTIME_DIR/packages/`. Using a symlink means the NED binary lives in one place (install dir) and can be shared across multiple runtime instances.  
If the symlink already exists it is removed and recreated (update-safe).

**Step 9 — Reload NSO packages** *(only with `--reload-packages`, NSO must be running)*
```
admin@ncs# packages reload
```
Triggers a live hot-reload. NSO compiles/validates the new NED YANG models without restarting. Output confirms `result true` per package.  
**Reload before loading devices** — `netsim_devices.sh --load-into-nso` needs the NED package loaded first, or `ncs_load` fails with "invalid value for ned-id".

**Netsim network** *(created by `netsim_devices.sh --create`, not `install_ned.sh`)*

*Device prefix* is derived from the NED name if `--prefix` is not given:
| NED name contains | Prefix |
|---|---|
| `iosxr` | `xr` |
| `ios-cli` | `ios` |
| `nx-cli` | `nx` |
| `asa-cli` | `asa` |
| anything else | first segment before `-` |

If `RUNTIME_DIR/netsim` does **not** exist:
```bash
ncs-netsim create-network <NED_PKG_DIR> <count> <prefix> --dir ~/nso-run-6.7/netsim
```

If `RUNTIME_DIR/netsim` **already** exists (subsequent NED installs):
```bash
ncs-netsim add-to-network <NED_PKG_DIR> <count> <prefix> --dir ~/nso-run-6.7/netsim
```

Then starts all devices:
```bash
ncs-netsim start --dir ~/nso-run-6.7/netsim
```

Each netsim device is a lightweight process that emulates a real device over SSH/NETCONF using the NED's YANG models. Ports are auto-assigned (CLI starts at 10022, NETCONF at 12022, IPC at 5010, etc.).

**Device init XML** *(generated and loaded by `netsim_devices.sh --load-into-nso`)*
```bash
# Generate XML with all device definitions
ncs-netsim --dir ~/nso-run-6.7/netsim ncs-xml-init \
  > ~/nso-run-6.7/ncs-cdb/netsim-devices.xml

# Load into live NSO CDB
ncs_load -l -m ~/nso-run-6.7/ncs-cdb/netsim-devices.xml
```
`ncs-xml-init` generates a `<devices>` XML document with one `<device>` entry per netsim device, pre-populated with address, port, SSH host keys, authgroup, and NED ID.  
`ncs_load -l -m` merges (`-m`) the XML into the live (`-l`) CDB without restarting NSO.

> **Note on `--dir` flag position:** `ncs-netsim` requires `--dir` *before* the subcommand, not after. `ncs-netsim ncs-xml-init --dir X` silently fails; the correct form is `ncs-netsim --dir X ncs-xml-init`.

### After running

```bash
cd ~/nso-run-6.7
ncs_cli -u "${NSO_ADMIN_USER}" -C

# Fetch SSH host keys (needed first time, or after netsim devices are recreated)
admin@ncs# devices device xr0 ssh fetch-host-keys
admin@ncs# devices device xr1 ssh fetch-host-keys
admin@ncs# devices device xr2 ssh fetch-host-keys

# Sync config from all devices
admin@ncs# devices sync-from

# Verify
admin@ncs# show devices list
```

---

## 3. `uninstall_nso_local.sh` — Remove NSO

**Purpose:** Cleanly remove NSO, its runtime, and shell profile entries.

```bash
./scripts/uninstall_nso_local.sh --clean-profiles -y
```

### What happens, step by step

**Step 1 — Parse options and resolve directories**
- Auto-detects the installed version from `~/nso-[0-9]*` glob (newest match, excluding `nso-run-*`).
- Can be overridden with `--version`, `--install-dir`, `--runtime-dir`.
- Expands any `~` in paths to `$HOME`.

**Step 2 — Confirmation prompt** *(skipped with `-y` / `--yes`)*
Lists what will be deleted and waits for `y/Y` before continuing.

**Step 3 — Stop NSO** *(if running)*
Uses a PID-file check instead of `ncs --status` to avoid hanging when NSO is not running:
```bash
pid=$(cat ~/nso-run-6.7/logs/ncs.pid)
kill -0 $pid   # check process exists
cd ~/nso-run-6.7 && ncs --stop
```
`ncs --status` can block indefinitely if the daemon is already down. The PID approach (`kill -0`) returns immediately.

**Step 4 — Source `ncsrc`**
Sources `~/nso-<version>/ncsrc` before calling `ncs --stop` so that the `ncs` binary is on `PATH`. Uses the same `set +u` / `set -u` guard.

**Step 5 — Remove the runtime directory** *(skipped with `--keep-runtime`)*
```bash
rm -rf ~/nso-run-6.7
```
Deletes: `ncs.conf`, `ncs-cdb/` (database), `logs/`, `state/`, `packages/` symlinks, `netsim/`.

**Step 6 — Remove the install directory**
```bash
rm -rf ~/nso-6.7
```
Deletes all NSO binaries, libraries, YANG models, example packages, and built-in NEDs.

**Step 7 — Clean shell profile entries** *(only with `--clean-profiles`)*
Removes the lines added by `install_nso_local.sh` from `~/.zprofile`, `~/.zshrc`, and `~/.bash_profile`:
```
# Added by install_nso_local.sh
source "/Users/.../nso-6.7/ncsrc"
```
Uses a temp-file approach (`grep -Fv` → temp → `mv`) instead of `sed -i` to avoid macOS `sed` portability issues with in-place editing.

**After running:** Open a new terminal (or `exec zsh`) for `PATH` changes to take effect.

---

## Common Workflows

### Fresh install + start
```bash
# Fetches the installer into the shared store, or pass a local .installer.bin path
./scripts/install_nso_local.sh --fetch --persist-env --start --verify
```

### Install a NED, then create simulated devices
```bash
# 1. Install the NED (local path or vendor slug)
./scripts/install_ned.sh cisco-iosxr --reload-packages

# 2. Create and load netsim devices
./scripts/netsim_devices.sh \
  --ned-dir ~/nso-6.7/packages/neds/cisco-iosxr-cli-7.76 \
  --create --devices 3 --load-into-nso
```

### Fetch SSH host keys and sync (after first install or device recreation)
```bash
cd ~/nso-run-6.7
ncs_cli -u "${NSO_ADMIN_USER}" -C
# For each device:
admin@ncs# devices device xr0 ssh fetch-host-keys
admin@ncs# devices sync-from
```

### Full teardown
```bash
./scripts/uninstall_nso_local.sh --clean-profiles -y
```

### RESTCONF API quick test
```bash
curl -su "${NSO_ADMIN_USER}:${NSO_ADMIN_PASSWORD}" \
  -H 'Accept: application/yang-data+json' \
  http://localhost:8080/restconf/data/tailf-ncs:devices
```
