# Manual MCP Server Install

Covers how to install the `cisco-nso-adaptive-mcp-server` package from a signed bundle and verify the `/mcp` endpoint.

Assumes NSO is already installed and running. See the `af-nso-local-install` skill if it is not.

---

## What is the NSO MCP Server?

The MCP server is an NSO package that exposes a [Model Context Protocol](https://spec.modelcontextprotocol.io/) endpoint at `/mcp` on the NSO WebUI HTTP port. It allows MCP-compatible AI assistants and clients to read NSO data and invoke NSO operations using standard NSO authentication and NACM authorization.

It uses a hybrid architecture:
- An **Erlang proxy** (`ec_cisco_nso_mcp_appmod`) registers the `/mcp` Yaws route and handles authentication
- A **Java `ApplicationComponent`** (`McpServerComponent`) discovers tools, resources, and prompts from the live NSO schema and services requests via a Unix domain socket (`state/mcp.sock`)

---

## Step 1 — Source the NSO environment

```bash
source ~/nso-6.7/ncsrc
```

---

## Step 2 — Extract the signed bundle

```bash
EXTRACT_DIR=$(mktemp -d)
cd "$EXTRACT_DIR"
sh /path/to/ncs-6.7-cisco-nso-adaptive-mcp-server-1.0.0.signed.bin
```

This downloads Cisco CA certificates from `cisco.com`, validates the cryptographic signature, and extracts the tarball.

```bash
ls "$EXTRACT_DIR"/*.tar.gz
# expected: ncs-6.7-cisco-nso-adaptive-mcp-server-1.0.0.tar.gz
```

Get the package directory name directly from the tarball before extracting:

```bash
PKG_NAME=$(tar -tzf "$EXTRACT_DIR"/*.tar.gz | head -1 | tr -d '/')
echo "$PKG_NAME"
# expected: cisco-nso-adaptive-mcp-server
```

Reading the name from the tarball is more reliable than scanning `package-meta-data.xml` after the fact, which can match unrelated packages already installed.

---

## Step 3 — Install into the NSO packages directory

```bash
NEDS_DIR="$HOME/nso-6.7/packages/neds"
mkdir -p "$NEDS_DIR"

tar -zxf "$EXTRACT_DIR"/*.tar.gz -C "$NEDS_DIR"

ls "$NEDS_DIR/$PKG_NAME/"
# package-meta-data.xml  erlang-lib/  load-dir/  private-jar/  src/  ...
```

---

## Step 4 — Symlink into the runtime packages directory

```bash
RUNTIME_PKGS="$HOME/nso-run-6.7/packages"

rm -f "$RUNTIME_PKGS/$PKG_NAME"
ln -sf "$NEDS_DIR/$PKG_NAME" "$RUNTIME_PKGS/$PKG_NAME"

ls -la "$RUNTIME_PKGS/" | grep mcp
```

---

## Step 5 — First `packages reload`

```
admin@ncs# packages reload
```

Expected output includes:

```
reload-result {
    package cisco-nso-adaptive-mcp-server
    result true
}
```

After this reload, the Java backend starts and the Unix socket is created:

```bash
ls ~/nso-run-6.7/state/mcp.sock   # should exist
```

The MCP log shows only:

```
cisco-nso-mcp-server.log:
  starting
  state dir cached: /Users/.../nso-run-6.7/state
```

**The `/mcp` endpoint is NOT yet registered.** `curl POST /mcp` returns 404.

---

## Step 6 — Second `packages reload`

```
admin@ncs# packages reload
```

This second reload triggers the Yaws route registration. The MCP log now shows:

```
cisco-nso-mcp-server.log:
  re-registering yaws appmod after reload
  initializing mcp proxy
  mcp proxy: registered /mcp on localhost:8080 (SSL: false)
  mcp proxy: matchHostName=true
```

**Why two reloads?** The Erlang app uses a `get_started()` persistent-term flag. On first load the flag is false — it is set but `trigger_yaws_set_conf()` is not called. On second load the flag is true — `trigger_yaws_set_conf()` fires and NSO calls `yaws_set_conf/1` on all Erlang modules that export it, including the MCP appmod which registers the `/mcp` route.

---

## Step 7 — Verify

```bash
curl -u "${NSO_ADMIN_USER}:${NSO_ADMIN_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d '{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
          "protocolVersion": "2025-03-26",
          "capabilities": {},
          "clientInfo": {"name": "test", "version": "1.0"}
        }
      }' \
  http://localhost:8080/mcp
```

Expected response:

```json
{
  "id": 1,
  "jsonrpc": "2.0",
  "result": {
    "authenticatedUser": "admin",
    "capabilities": {
      "prompts": {"listChanged": true},
      "resources": {"listChanged": true, "subscribe": false},
      "tools": {"listChanged": true}
    },
    "protocolVersion": "2025-03-26",
    "serverInfo": {
      "name": "cisco-nso-adaptive-mcp-server",
      "version": "1.0.0"
    }
  }
}
```

List available tools:

```bash
curl -u "${NSO_ADMIN_USER}:${NSO_ADMIN_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  http://localhost:8080/mcp
```

With default `restricted` policy, expect 11 tools: `echo`, device ops (`sync-from`, `sync-to`, `check-sync`, `compare-config`, `connect`, `disconnect`, `ping`), and read helpers (`nso_read_schema`, `nso_read_config`, `nso_read_operational`).

---

## Removing the MCP Server

### Quick removal (script)

```bash
bash scripts/uninstall_mcp.sh
# add -y to skip confirmation
# add --keep-package to preserve the package in packages/neds/
```

### Manual removal

```bash
# 1. Remove the runtime symlink
rm ~/nso-run-6.7/packages/cisco-nso-adaptive-mcp-server

# 2. Reload packages — NSO unloads the package, /mcp returns 404
echo "packages reload" | ncs_cli -u "${NSO_ADMIN_USER}" -C

# 3. Verify
curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8080/mcp
# expected: 404

# 4. Optionally remove from install dir (permanent)
rm -rf ~/nso-6.7/packages/neds/cisco-nso-adaptive-mcp-server
```
