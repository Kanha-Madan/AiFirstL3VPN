# install_mcp.sh and uninstall_mcp.sh — Script Reference

Two scripts cover the full install/removal lifecycle of the `cisco-nso-adaptive-mcp-server` package.

---

## 1. `install_mcp.sh`

Installs the `cisco-nso-adaptive-mcp-server` NSO package from a signed bundle, wires it into the runtime, performs the mandatory double `packages reload`, and verifies the `/mcp` endpoint.

---

## Usage

```bash
# Resolve from the shared store (reuse if present, else download), then install
bash scripts/install_mcp.sh \
  [--nso-version VER] \
  [--install-dir PATH] [--runtime-dir PATH] \
  [--host HOST] [--port PORT] [--user USER] [--pass PASS]

# Or install a local bundle directly
bash scripts/install_mcp.sh \
  /path/to/ncs-6.7-cisco-nso-adaptive-mcp-server-1.0.0.signed.bin \
  [--install-dir PATH] [--runtime-dir PATH] \
  [--host HOST] [--port PORT] [--user USER] [--pass PASS]
```

---

## What happens, step by step

**Step 1 — Resolve the input bundle**
If the first argument is an existing `.signed.bin`/`.tar.gz`/`.tgz` file it is used
directly. Otherwise (or with `--fetch`, or when no positional is given) the argument
is treated as a vendor slug — defaulting to `cisco-nso-adaptive-mcp-server` — and
resolved from the shared XDG store via `fetch_ned.sh`, which reuses an existing
download or fetches one. `--nso-version <ver>` overrides the auto-detected NSO
version during resolution.

**Step 2 — Auto-detect NSO directories**
- Finds the newest `~/nso-[0-9]*` directory (excluding `nso-run-*`) → `INSTALL_DIR`
- Finds the newest `~/nso-run-*` directory → `RUNTIME_DIR`
- Both can be overridden with `--install-dir` / `--runtime-dir`

**Step 3 — Source `ncsrc`**
Uses `set +u` / `set -u` guard to handle unset `DYLD_LIBRARY_PATH` safely. Provides `ncs_cli` on `PATH`.

**Step 4 — Extract the signed bundle** *(`.signed.bin` only)*
```bash
EXTRACT_DIR=$(mktemp -d)
cd "$EXTRACT_DIR" && sh <signed.bin>
```
- Downloads Cisco CA certificates from `cisco.com` and validates the cryptographic signature
- Extracts the `.tar.gz` into the temp dir
- A `trap` ensures the temp dir is cleaned up on exit, even on failure

**Step 5 — Determine the package directory name from the tarball**
```bash
PKG_NAME=$(tar -tzf <tarball> | head -1 | tr -d '/')
```
This reads the top-level directory name directly from the tarball — more reliable than scanning `package-meta-data.xml` files on disk, which can match unrelated packages already installed in `packages/neds/`.

**Step 6 — Extract into `packages/neds/`**
```bash
tar -zxf <tarball> -C ~/nso-6.7/packages/neds/
```

**Step 7 — Symlink into runtime packages**
```bash
rm -f ~/nso-run-6.7/packages/<pkg-name>
ln -sf ~/nso-6.7/packages/neds/<pkg-name> ~/nso-run-6.7/packages/<pkg-name>
```
Removes any stale symlink before creating a fresh one (update-safe).

**Step 8 — First `packages reload`**
```bash
echo "packages reload" | ncs_cli -u "${NSO_ADMIN_USER}" -C
```
Loads the YANG schema, starts the Java `McpServerComponent`, creates `state/mcp.sock`. The Erlang proxy starts but does NOT yet register the `/mcp` route.

**Step 9 — Second `packages reload`**
```bash
echo "packages reload" | ncs_cli -u "${NSO_ADMIN_USER}" -C
```
The Erlang app's `get_started()` flag is now `true`. `ec_util:trigger_yaws_set_conf()` fires, NSO calls `yaws_set_conf/1` on the appmod, and the `/mcp` Yaws route is registered.

**Step 10 — Verify the `/mcp` endpoint**
```bash
curl -s -o /dev/null -w "%{http_code}" -u "${NSO_ADMIN_USER}:${NSO_ADMIN_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}' \
  http://localhost:8080/mcp
# expected: 200
```
Exits with error if the endpoint does not return HTTP 200.

---

## Key design decisions

### Why `tar -tzf | head -1` for the package name?

The `af-nso-install-ned` script used `find packages/neds/ -name package-meta-data.xml | sort | tail -1` to find the newly installed package. This is fragile when other packages are already present — the "newest" `package-meta-data.xml` can point to a different package if timestamps are not strictly ordered. Reading the directory name from the tarball itself is deterministic regardless of what else is installed.

### Why two `packages reload`?

See [install-mcp.md — Step 6](./install-mcp.md#step-6--second-packages-reload) for the full explanation. Short version: the Erlang app's `get_started()` flag means the Yaws route is only registered on the second application start, not the first.

### Why not restart NSO instead?

A full NSO restart would also work (the app would start cold with `get_started()` false, then NSO's Yaws startup would call `yaws_set_conf/1`). But `packages reload` is non-disruptive — it hot-reloads without losing CDB state, active sessions, or device connections.

---

## 2. `uninstall_mcp.sh`

Removes the `cisco-nso-adaptive-mcp-server` package from the NSO runtime and optionally from the install directory.

### Usage

```bash
bash scripts/uninstall_mcp.sh [options]
```

### Options

| Option | What it does |
|---|---|
| `--runtime-dir PATH` | Override auto-detected `~/nso-run-<version>` |
| `--install-dir PATH` | Override auto-detected `~/nso-<version>` |
| `--keep-package` | Remove runtime symlink only; keep package in `packages/neds/` |
| `--user USER` | NSO admin user for `packages reload` (default: `admin`) |
| `-y` / `--yes` | Skip confirmation prompt |

### What happens, step by step

**Step 1 — Auto-detect NSO directories**
Same auto-detection logic as `install_mcp.sh`.

**Step 2 — Confirm the package is installed**
Checks for the symlink at `~/nso-run-<version>/packages/cisco-nso-adaptive-mcp-server`. If not found, exits cleanly with a message.

**Step 3 — Confirmation prompt** *(skipped with `-y`)*
Lists what will be removed and waits for `y/Y`.

**Step 4 — Remove runtime symlink**
```bash
rm ~/nso-run-6.7/packages/cisco-nso-adaptive-mcp-server
```
Only the symlink is removed at this stage; the package in `packages/neds/` is untouched.

**Step 5 — `packages reload`**
```bash
echo "packages reload" | ncs_cli -u "${NSO_ADMIN_USER}" -C
```
NSO unloads the package. The Erlang app stops, the Yaws `/mcp` route is deregistered, and the Unix socket is closed.

**Step 6 — Remove from install dir** *(unless `--keep-package`)*
```bash
rm -rf ~/nso-6.7/packages/neds/cisco-nso-adaptive-mcp-server
```
Permanently removes the package from disk. Use `--keep-package` if you want to re-enable later by re-creating the symlink.

**Step 7 — Verify**
Confirms `curl POST /mcp` now returns HTTP 404 (not 200).

### Re-enabling after `--keep-package`

If the package was kept in the install dir, re-enable without re-extracting:

```bash
ln -sf ~/nso-6.7/packages/neds/cisco-nso-adaptive-mcp-server \
       ~/nso-run-6.7/packages/cisco-nso-adaptive-mcp-server
# then run packages reload twice (see install_mcp.sh double-reload requirement)
echo "packages reload" | ncs_cli -u "${NSO_ADMIN_USER}" -C
echo "packages reload" | ncs_cli -u "${NSO_ADMIN_USER}" -C
```
