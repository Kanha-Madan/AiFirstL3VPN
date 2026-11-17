---
name: af-nso-install-mcp
description: 'Cisco NSO MCP server install and removal. Use for: install MCP server, add MCP, enable MCP endpoint, remove MCP, uninstall MCP, disable MCP endpoint, install cisco-nso-adaptive-mcp-server, MCP signed bin, packages reload mcp, run install_mcp.sh, run uninstall_mcp.sh. Resolves the MCP package from the shared system store (fetch_ned.sh reuses or downloads). Covers: signed.bin extraction, double packages reload, Yaws route registration, /mcp endpoint verification, clean removal.'
argument-hint: 'e.g. "install MCP server", "enable NSO MCP endpoint", "remove MCP", "uninstall MCP server"'
license: Proprietary
---

# NSO MCP Server Install / Removal

Installs or removes the `cisco-nso-adaptive-mcp-server` package in a running NSO instance.

This is **not** a standard NED install. Key differences:

| Step | NED install | MCP install |
|---|---|---|
| `packages reload` count | 1 | **2** (see below) |
| Symlink name | derived from tarball | derived from tarball |
| Verification | `ned-id` in CLI | `curl POST /mcp` → HTTP 200 |
| Follow-up | create netsim devices | none |

---

## Resolve the MCP Package — Do This First

The MCP package lives in the **shared system store**
(`~/.local/share/aifirst/binaries/neds/`) — the same place NEDs go, shared across
projects. Resolve it via the NED fetcher, which **reuses a cached bundle or
downloads it** and prints the absolute path:

```bash
MCP_BIN="$(../af-nso-install-ned/scripts/fetch_ned.sh cisco-nso-adaptive-mcp-server)"
```

On first download you are prompted for your Tail-F credentials (stored in the
macOS Keychain, never written to disk). `$MCP_BIN` is the `.signed.bin` path to
pass to `install_mcp.sh` below.

> Only if auto-download is unavailable (no VPN/credentials) fall back to copying a
> bundle into the system store manually:
> ```bash
> cp ~/Downloads/ncs-*-cisco-nso-adaptive-mcp-server-*.signed.bin ~/.local/share/aifirst/binaries/neds/
> ```
> Source: [https://dl.tail-f.com:9443](https://dl.tail-f.com:9443/ncs-pkgs/cisco-nso-adaptive-mcp-server/). Never use `software.cisco.com`.

---

## Install

```bash
# One step: install_mcp.sh resolves the package from the shared store itself
# (reuses it, or downloads via fetch_ned.sh), then installs it
bash scripts/install_mcp.sh

# Or pass a pre-resolved bundle path
bash scripts/install_mcp.sh "$MCP_BIN"
```

The script handles everything including the mandatory double reload.

### All options

| Option | What it does |
|---|---|
| `--install-dir PATH` | Override auto-detected `~/nso-<version>` |
| `--runtime-dir PATH` | Override auto-detected `~/nso-run-<version>` |
| `--host HOST` | NSO host for verification (default: `localhost`) |
| `--port PORT` | NSO WebUI port for verification (default: `8080`) |
| `--user USER` | NSO admin user for verification (default: `$NSO_ADMIN_USER` env var, else `admin`) |
| `--pass PASS` | NSO admin password for verification (required: `$NSO_ADMIN_PASSWORD` env var or this flag) |

### What the script does (step by step)

1. Auto-detects `~/nso-[0-9]*` (install) and `~/nso-run-*` (runtime) dirs
2. Sources `ncsrc` with `set +u` / `set -u` guard
3. Extracts `signed.bin` in `mktemp -d` — cert files stay out of the system store
4. Reads the top-level directory name from the tarball (`tar -tzf | head -1`) — avoids misidentifying unrelated packages
5. `tar -zxf <tarball> -C ~/nso-6.7/packages/neds/`
6. Creates `~/nso-run-6.7/packages/<pkg-name>` → symlink to install dir
7. **First `packages reload`** — loads the package, starts the Java backend, creates the Unix socket at `state/mcp.sock`
8. **Second `packages reload`** — the Erlang app's `get_started()` flag is now `true`, so `ec_util:trigger_yaws_set_conf()` fires and registers the `/mcp` Yaws route
9. Verifies the endpoint with `curl POST /mcp` (`initialize` request) — expects HTTP 200

---

## Why Two Reloads?

The Erlang proxy (`ec_cisco_nso_mcp_app`) uses a persistent-term flag to distinguish first load from reload:

```erlang
case get_started() of
    true  -> ec_util:trigger_yaws_set_conf();   % reload: re-register route
    false -> set_started()                       % first load: just set flag
end
```

On **first** `packages reload`: `get_started()` is false → flag is set, route is NOT registered → `/mcp` returns 404.  
On **second** `packages reload`: `get_started()` is true → `trigger_yaws_set_conf()` fires → Yaws calls `yaws_set_conf/1` → route is registered → `/mcp` works.

This is by design: NSO calls `yaws_set_conf/1` on all modules automatically on reload, but the Erlang app cannot know when NSO has finished its own startup on cold boot. The double-reload pattern is the correct way to handle this.

---

## Verification

After install, the MCP log confirms the route registration:

```
cisco-nso-mcp-server.log:
  re-registering yaws appmod after reload
  initializing mcp proxy
  mcp proxy: registered /mcp on localhost:8080 (SSL: false)
```

And the endpoint responds:

```bash
curl -u "${NSO_ADMIN_USER}:${NSO_ADMIN_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  http://localhost:8080/mcp
# → {"result":{"protocolVersion":"2025-03-26","serverInfo":{"name":"cisco-nso-adaptive-mcp-server",...}}}
```

The package also ships with a full smoke test:

```bash
bash ~/nso-6.7/packages/neds/cisco-nso-adaptive-mcp-server/test-mcp.sh
```

---

## Troubleshooting

### `/mcp` returns 404 after one reload

Run `packages reload` a second time. The Yaws route is only registered on the second load.

### `/mcp` returns 503 — "MCP server not running"

The Erlang proxy is up but the Java backend Unix socket is missing. Check:

```bash
ls ~/nso-run-6.7/state/mcp.sock          # should exist
tail -30 ~/nso-run-6.7/logs/ncs-java-vm.log | grep -i mcp
```

If the log shows `Unix domain path too long`, your NSO runtime path is too long for macOS. Shorten `~/nso-run-<version>` and restart.

### `400 Bad Request` on `/mcp`

`/ncs-config/webui/match-host-name` is `true` in `ncs.conf`. Use `localhost` (not `127.0.0.1`) in the URL, or set `--host localhost` explicitly.

### Only a few tools visible (not all expected tools)

Default policy is `restricted`. Permitted tools: `echo`, device ops, read helpers. To expose service tools:

```xml
<mcp-server xmlns="http://cisco.com/pkg/cisco-nso-mcp">
  <policies>
    <default-action>permit</default-action>
  </policies>
</mcp-server>
```

Or use targeted permit rules — see the MCP server documentation.

---

## Uninstall

```bash
bash scripts/uninstall_mcp.sh
```

### All options

| Option | What it does |
|---|---|
| `--runtime-dir PATH` | Override auto-detected `~/nso-run-<version>` |
| `--install-dir PATH` | Override auto-detected `~/nso-6.7` |
| `--keep-package` | Remove runtime symlink only; keep package in install dir (`packages/neds/`) |
| `--user USER` | NSO admin user for `packages reload` (default: `$NSO_ADMIN_USER` env var, else `admin`) |
| `-y` / `--yes` | Skip confirmation prompt |

### What the script does

1. Confirms the `cisco-nso-adaptive-mcp-server` package is present in the runtime
2. Prompts for confirmation *(skipped with `-y`)*
3. Removes the runtime symlink: `~/nso-run-6.7/packages/cisco-nso-adaptive-mcp-server`
4. Runs `packages reload` — NSO unloads the package and the `/mcp` route is deregistered
5. Unless `--keep-package`: removes the package from the install dir (`~/nso-6.7/packages/neds/cisco-nso-adaptive-mcp-server`)
6. Verifies the `/mcp` endpoint now returns 404

### Manual removal (without script)

```bash
# 1. Remove the runtime symlink
rm ~/nso-run-6.7/packages/cisco-nso-adaptive-mcp-server

# 2. Reload packages — deregisters the /mcp route
echo "packages reload" | ncs_cli -u "${NSO_ADMIN_USER}" -C

# 3. Optionally remove from install dir
rm -rf ~/nso-6.7/packages/neds/cisco-nso-adaptive-mcp-server
```

---

## Reference Docs

- [references/install-mcp.md](./references/install-mcp.md) — manual step-by-step walkthrough (install and removal)
- [references/SCRIPTS.md](./references/SCRIPTS.md) — script mechanics for both `install_mcp.sh` and `uninstall_mcp.sh`
