---
name: af-nso-local-install
description: 'Cisco NSO install and uninstall on macOS. Use for: install NSO, set up NSO, fresh NSO install, uninstall NSO, remove NSO, reinstall NSO, run install_nso_local.sh, run uninstall_nso_local.sh. Resolves the installer from the shared system store (install_nso_local.sh --fetch reuses or downloads). Covers: local install, ncsrc, JAVA_HOME, runtime setup, ncs-setup, RESTCONF, persist-env, dev mode, shell profiles cleanup.'
argument-hint: 'action — e.g. "install NSO", "uninstall NSO", "reinstall with RESTCONF"'
license: Proprietary
---

# NSO Install / Uninstall

Handles installing and removing Cisco NSO locally on macOS (arm64).

## Resolve the Installer — Do This First

The NSO installer lives in the **shared system store**
(`~/.local/share/aifirst/binaries/nso/`, overridable via `AIFIRST_HOME` or
`AIFIRST_BINARIES_DIR`) — shared across projects, never in the project tree. You
don't inspect a project folder; `install_nso_local.sh --fetch` resolves it against
the system store and **reuses or downloads** it (same Keychain credential flow as
NED downloads):

```bash
# Fetch the latest installer for this host, then install
scripts/install_nso_local.sh --fetch --start --verify
# Or fetch a specific NSO version
scripts/install_nso_local.sh 6.7 --start --verify
```

`install_nso_local.sh` resolves `nso-<ver>.<os>.<arch>.installer.bin` for the host
(architecture normalized) via the manifest
(`~/.cache/aifirst/ned-catalog/manifest.txt`), downloads it into the system store,
verifies its checksum, then installs. If the user hands you an explicit installer
path, pass it directly instead.

---

## Install NSO

```bash
# Default latest-version install (only when no version is required)
scripts/install_nso_local.sh --fetch \
  --persist-env --start --verify

# Required-version install: do NOT reuse an already-installed different NSO
scripts/install_nso_local.sh 6.4.1 \
  --persist-env --start --verify
```

### Exact version policy

If a project or spec explicitly requires a version such as `6.4.1`, the requested version is authoritative and must be installed and started even when a different version like `6.5.1` is already present locally.

Use this rule:
- `install_nso_local.sh <version>` when the target is known and pinned
- `af-nso-version-switch` when switching from one installed version to another
- never call the generic `--fetch` flow for a project that has a pinned NSO requirement

This prevents accidental reuse of an unrelated runtime and ensures a fresh runtime directory is created for the required version.

### All options

| Option | What it does |
|---|---|
| `--persist-env` | Append `source ncsrc` (and the admin credential file when one exists) to `~/.zprofile`, `~/.zshrc`, `~/.bash_profile` |
| `--start` | `cd RUNTIME_DIR && ncs` after setup; also provisions the admin password |
| `--insecure-default-admin` | Do not fail when NSO is not running; the known NSO default admin password stays in force (throwaway development only) |
| `--verify` | Check dirs, ncsrc, ncs.conf, binaries |
| `--explore` | List examples, NEDs, doc path |
| `--dev-mode` | Enable development license (requires `--start`) |
| `--enable-restconf` | Patch `ncs.conf` to enable RESTCONF API |
| `--restconf-port N` | WebUI/RESTCONF port (default: 8080) |
| `--install-dir PATH` | Override `~/nso-<version>` |
| `--runtime-dir PATH` | Override `~/nso-run-<version>` |

### What the script does (step by step)
1. Parses version from filename (`nso-6.7...` → `6.7`)
2. Runs `sh <installer.bin> ~/nso-6.7 --local-install` (skips if `ncsrc` already exists)
3. Sources `ncsrc` with `set +u` / `set -u` guard
4. Runs `ncs-setup --dest ~/nso-run-6.7` (skips if `ncs.conf` exists)
5. Patches `ncs.conf` via Python3 for RESTCONF if requested
6. Starts NSO: `cd ~/nso-run-6.7 && ncs`
7. With NSO running, provisions the admin password (see Credentials below)
8. Appends `source ncsrc` to shell profiles (idempotent)

### Credentials

The NSO default `admin` password is not left in force. With NSO running (`--start`, or already up) the script:

1. Picks the password: `$NSO_ADMIN_PASSWORD` if set, else the value saved in `<runtime>/nso-admin.env`, else 24 random alphanumeric characters from `/dev/urandom`.
2. Sets it on the NSO admin user through `ncs_load`, which hashes it. The value goes by stdin only, never on a command line or in output.
3. Saves `NSO_ADMIN_USER` and `NSO_ADMIN_PASSWORD` to `<runtime>/nso-admin.env` (mode 600). Load them with `source <runtime>/nso-admin.env`; `--persist-env` adds a guarded line to the shell profiles.
4. With `--enable-restconf`, logs in over RESTCONF with the new credentials and fails on 401/403.

Re-running reuses the saved value, so it does not rotate. Without a running NSO the script fails rather than leave the default in force, unless `--insecure-default-admin` is given. Never print or echo `NSO_ADMIN_PASSWORD`.

---

## Uninstall NSO

```bash
scripts/uninstall_nso_local.sh --clean-profiles -y
```

> Scripts are at [./scripts/](./scripts/)

### All options

| Option | What it does |
|---|---|
| `--version VER` | NSO version (auto-detected from `~/nso-*`) |
| `--install-dir PATH` | Override install dir |
| `--runtime-dir PATH` | Override runtime dir |
| `--keep-runtime` | Delete software but preserve CDB and config |
| `--clean-profiles` | Remove `source ncsrc` lines from shell profiles |
| `-y / --yes` | Skip confirmation prompt |

### What the script does (step by step)
1. Auto-detects version from `~/nso-[0-9]*` glob
2. PID-file check (`kill -0 $(cat logs/ncs.pid)`) — stops NSO if running
3. `rm -rf ~/nso-run-<version>` (unless `--keep-runtime`)
4. `rm -rf ~/nso-<version>`
5. `grep -Fv` + temp file to strip profile entries, including the admin credential line (avoids macOS `sed -i` issues)

---

## Key Facts

- **JAVA_HOME must be set:** `export JAVA_HOME="/opt/homebrew/opt/openjdk@21"`
- **ncsrc sourcing:** `set +u; source ~/nso-6.7/ncsrc; set -u` — the `set +u` guard prevents `DYLD_LIBRARY_PATH: unbound variable` errors
- **Runtime dir rule:** `ncs` daemon must always be started from `~/nso-run-<version>`. Running from elsewhere → `Cannot access directory ./state` (exit 21)
- **PID check vs ncs --status:** `ncs --status` blocks indefinitely when NSO is not running. Use `kill -0 $(cat logs/ncs.pid)` instead

---

## Day-to-day Commands

```bash
# Start NSO
cd ~/nso-run-6.7 && ncs

# Stop NSO
cd ~/nso-run-6.7 && ncs --stop

# Check status
cd ~/nso-run-6.7 && ncs --status | grep status

# Open CLI
ncs_cli -u "${NSO_ADMIN_USER}" -C
```

---

## Reference Docs
- [references/install-nso.md](./references/install-nso.md) — full manual install walkthrough
- [references/uninstall-nso.md](./references/uninstall-nso.md) — full manual uninstall walkthrough
- [references/SCRIPTS.md](./references/SCRIPTS.md) — internal script mechanics
