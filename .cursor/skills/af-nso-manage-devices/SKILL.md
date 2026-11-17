---
name: af-nso-manage-devices
description: 'NSO netsim device lifecycle and device configuration. Use for: create netsim devices, add devices, destroy netsim, start/stop netsim, load devices into NSO, fetch SSH host keys, sync-from, configure device, push config, RESTCONF API, ncs_cli, show devices, rollback config, device management, run netsim_devices.sh. Covers: ncs-netsim, ncs_load, SSH host keys, sync-from, NSO CLI config, RESTCONF curl, NETCONF.'
argument-hint: 'action — e.g. "create 3 iosxr devices", "sync devices", "push loopback config via RESTCONF"'
license: Proprietary
---

# NSO Device Management

Covers two phases of the dev loop:
1. **Netsim lifecycle** — create, start, stop, destroy simulated devices
2. **Device configuration** — push and read config via NSO CLI, RESTCONF, or NETCONF

---

## Phase 1 — Netsim Lifecycle

### Create devices

Requires the NED to already be installed and loaded. See `nso-ned` skill if not done.

**Important:** `--create` now **automatically deletes** any existing netsim setup before creating a fresh network. This ensures a clean state and avoids device conflicts.

```bash
scripts/netsim_devices.sh --create \
  --ned-dir ~/nso-6.7/packages/neds/cisco-iosxr-cli-7.76 \
  --devices 3 \
  --load-into-nso
```

Then fetch SSH host keys and sync:

```bash
scripts/netsim_devices.sh --fetch-keys
scripts/netsim_devices.sh --sync-from
```

> Script is at [./scripts/netsim_devices.sh](./scripts/netsim_devices.sh)

### What happens during --create

1. **Checks for existing netsim** — if netsim directory exists:
   - Collects device names from current netsim
   - Stops all running netsim devices
   - Removes devices from NSO CDB (if NSO is running)
   - Deletes the netsim directory
2. **Creates fresh network** — `ncs-netsim create-network` with specified device count
3. **Starts devices** — automatically starts all netsim devices
4. **Loads into NSO** (if `--load-into-nso` flag is used) — generates device XML and loads via `ncs_load`

### All netsim_devices.sh actions

| Action | What it does |
|---|---|
| `--create` | **Deletes existing netsim**, then creates fresh network with specified device count |
| `--destroy` | Stop devices + `rm -rf netsim/` (prompts unless `-y`) |
| `--start` | `ncs-netsim start` — follow with `ncs-netsim is-alive` to confirm all devices show `DEVICE <name> OK` |
| `--stop` | `ncs-netsim stop` |
| `--restart` | `ncs-netsim restart` |
| `--list` | `ncs-netsim list` — shows all devices and ports |
| `--load` | `ncs-xml-init` → `ncs_load -l -m` (standalone, without creating devices) |
| `--remove-from-nso` | Remove all netsim devices from NSO CDB (reads names from netsim dir) |
| `--fetch-keys` | `devices fetch-ssh-host-keys` via ncs_cli |
| `--sync-from` | `devices sync-from` via ncs_cli |

> `--load-into-nso` is a **modifier** for `--create` — loads devices into NSO after creation.  
> `--remove-from-nso` is a **modifier** for `--destroy` — also removes devices from NSO CDB after destroying netsim. Can also be used standalone.

### Options for `--create`

| Option | Default |
|---|---|
| `--ned-dir PATH` | Required |
| `--devices N` | 3 |
| `--prefix NAME` | Derived: iosxr→xr, ios-cli→ios, nx-cli→nx, asa-cli→asa |
| `--netsim-dir PATH` | `<runtime-dir>/netsim` |
| `--runtime-dir PATH` | Auto-detect `~/nso-run-*` |
| `--install-dir PATH` | Auto-detect `~/nso-[0-9]*` |
| `-y / --yes` | — |

### Recreate devices from scratch

Since `--create` now automatically cleans up existing devices, simply run:

```bash
scripts/netsim_devices.sh --create \
  --ned-dir ~/nso-6.7/packages/neds/cisco-iosxr-cli-7.76 \
  --devices 3 --load-into-nso
scripts/netsim_devices.sh --fetch-keys
scripts/netsim_devices.sh --sync-from
```

The `--destroy` action is still available if you need to manually tear down without recreating:

```bash
scripts/netsim_devices.sh --destroy --remove-from-nso -y
```

To only remove devices from NSO CDB (without destroying netsim):
```bash
scripts/netsim_devices.sh --remove-from-nso
```

### Netsim port reference

| Port type | Starting value | Protocol |
|---|---|---|
| CLI | 10022 | SSH |
| NETCONF | 12022 | SSH |
| SNMP | 11022 | UDP |
| IPC (internal) | 5010 | TCP |

---

## Key Facts — Netsim

### `--dir` flag position (critical gotcha)
`--dir` must come **before** the subcommand in `ncs-netsim`:
- ✓ `ncs-netsim --dir ~/nso-run-6.7/netsim ncs-xml-init`
- ✗ `ncs-netsim ncs-xml-init --dir ~/nso-run-6.7/netsim` — silently fails, generates empty/wrong XML

### When to fetch SSH host keys
Run `--fetch-keys` after every `--create` — since it now always creates fresh devices with new SSH keys.
- `result false: Could not verify ssh-rsa host key` error from `sync-from`

### Start failures — where to look
If `ncs-netsim start` (or `--start`) reports a device failed, read that device's log before retrying:
```bash
cat <runtime-dir>/netsim/<prefix>/<device-name>/logs/confderr.log
```

### `ncs_load` requires packages loaded first
`--load-into-nso` uses `ncs_load -l -m`. NSO must have already loaded the NED package (`packages reload`) — otherwise `ncs_load` fails with "not a valid value for ned-id". Run `nso-ned` skill first.

---

## Phase 2 — Device Configuration

Open NSO CLI:
```bash
cd ~/nso-run-6.7
ncs_cli -u "${NSO_ADMIN_USER}" -C
```

### Read device config
```
admin@ncs# show devices list
admin@ncs# show running-config devices device xr0 config
admin@ncs# show devices device * sync-state
admin@ncs# devices device xr0 compare-config
```

### Push config (commit workflow)
```
admin@ncs# config
admin@ncs(config)# devices device xr0 config
admin@ncs(config-config)# interface Loopback 100
admin@ncs(config-Loopback)# ipv4 address 10.100.0.1 255.255.255.0
admin@ncs(config-Loopback)# exit
admin@ncs(config-config)# exit
admin@ncs(config)# commit dry-run outformat native
admin@ncs(config)# commit
```

### Push to multiple devices
```
admin@ncs(config)# devices device xr0..xr5 config
admin@ncs(config-config)# interface Loopback 200
admin@ncs(config-Loopback)# ipv4 address 10.200.0.1 255.255.255.0
admin@ncs(config-Loopback)# exit
admin@ncs(config)# commit
```

### Rollback
```
admin@ncs# show configuration rollback changes
admin@ncs(config)# rollback configuration
admin@ncs(config)# commit
```

### RESTCONF API

Requires RESTCONF enabled in `ncs.conf`. Default port: 8080.

```bash
# Read all devices
curl -su "${NSO_ADMIN_USER}:${NSO_ADMIN_PASSWORD}" \
  -H 'Accept: application/yang-data+json' \
  http://localhost:8080/restconf/data/tailf-ncs:devices/device

# Read device config
curl -su "${NSO_ADMIN_USER}:${NSO_ADMIN_PASSWORD}" \
  -H 'Accept: application/yang-data+json' \
  'http://localhost:8080/restconf/data/tailf-ncs:devices/device=xr0/config'

# Add a loopback interface
curl -su "${NSO_ADMIN_USER}:${NSO_ADMIN_PASSWORD}" -X PATCH \
  -H 'Content-Type: application/yang-data+json' \
  'http://localhost:8080/restconf/data/tailf-ncs:devices/device=xr0/config' \
  -d '{
    "tailf-ned-cisco-ios-xr:interface": {
      "Loopback": [{"id": 100, "ipv4": {"address": {"ip": "10.100.0.1", "mask": "255.255.255.0"}}}]
    }
  }'

# Sync-from via RESTCONF RPC
curl -su "${NSO_ADMIN_USER}:${NSO_ADMIN_PASSWORD}" -X POST \
  -H 'Content-Type: application/yang-data+json' \
  'http://localhost:8080/restconf/operations/tailf-ncs:devices/device=xr0/sync-from'
```

### NSO CLI quick reference

| Command | What it does |
|---|---|
| `commit dry-run` | Preview without applying |
| `commit dry-run outformat native` | Show raw device CLI/XML to be sent |
| `revert` | Discard all staged changes |
| `rollback configuration` | Roll back last commit |
| `devices sync-from` | Pull config from all devices |
| `devices sync-to` | Push NSO config to all devices |
| `devices device xr0 check-sync` | Non-destructive sync check |
| `devices disconnect` | Drop all open connections |

---

## Reference Docs
- [references/netsim-devices.md](./references/netsim-devices.md) — full netsim manual walkthrough
- [references/configure-devices.md](./references/configure-devices.md) — full CLI/RESTCONF/NETCONF guide
- [references/SCRIPTS.md](./references/SCRIPTS.md) — internal script mechanics
