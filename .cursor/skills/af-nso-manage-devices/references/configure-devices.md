# Connecting to Netsim Devices and Changing Configuration via NSO

Covers how to connect to netsim devices through NSO and push configuration changes using the NSO CLI, NETCONF, and RESTCONF interfaces.

Assumes NSO is running and devices are synced. See [netsim-devices.md](netsim-devices.md).

---

## How NSO manages device config

NSO sits between you and the devices. It keeps a local copy of each device's config in its CDB (Configuration Database). When you make changes in NSO, the flow is:

```
You → NSO CDB → commit → NSO pushes diff to device (via NETCONF/CLI)
```

You never talk to the device directly when using NSO. NSO translates your changes into the device's native protocol.

---

## Prerequisites

```bash
source ~/nso-6.7/ncsrc
export JAVA_HOME="/opt/homebrew/opt/openjdk@21"
cd ~/nso-run-6.7
```

Verify devices are present and synced:

```
admin@ncs# show devices list
```

If any device shows `sync-state: out-of-sync`, run:

```
admin@ncs# devices sync-from
```

---

## Part 1 — NSO CLI

The NSO CLI is the primary interface for configuration management.

```bash
ncs_cli -u "${NSO_ADMIN_USER}" -C
```

`-C` selects Cisco IOS XR-style CLI. The prompt becomes `admin@ncs#`.

### 1.1 — Inspect device config (read-only)

```
# Show all managed devices
admin@ncs# show devices list

# Show the full running config stored in NSO for a device
admin@ncs# show running-config devices device xr0

# Show only the interface config
admin@ncs# show running-config devices device xr0 config

# Show a specific interface
admin@ncs# show running-config devices device xr0 config interface MgmtEth

# Show sync state of all devices
admin@ncs# show devices device * sync-state

# Compare NSO's stored config to what is actually on the device
admin@ncs# devices device xr0 compare-config
```

### 1.2 — Enter configuration mode

```
admin@ncs# config
Entering configuration mode terminal
admin@ncs(config)#
```

All changes made in `config` mode are staged locally in NSO. Nothing is sent to the device until you `commit`.

### 1.3 — Add a loopback interface

```
admin@ncs(config)# devices device xr0 config
admin@ncs(config-config)# interface Loopback 100
admin@ncs(config-Loopback)# ipv4 address 10.100.0.1 255.255.255.0
admin@ncs(config-Loopback)# no shutdown
admin@ncs(config-Loopback)# exit
admin@ncs(config-config)# exit
```

Preview what will be sent to the device before committing:

```
admin@ncs(config)# show configuration
admin@ncs(config)# show configuration diff
```

Commit (sends the diff to the device via NETCONF/CLI):

```
admin@ncs(config)# commit
Commit complete.
```

Verify it was applied:

```
admin@ncs# show running-config devices device xr0 config interface Loopback 100
```

### 1.4 — Configure multiple devices at once

NSO can push the same change to all devices in one commit:

```
admin@ncs(config)# devices device xr0..xr5 config
admin@ncs(config-config)# interface Loopback 200
admin@ncs(config-Loopback)# ipv4 address 10.200.0.1 255.255.255.0
admin@ncs(config-Loopback)# exit
admin@ncs(config-config)# exit
admin@ncs(config)# commit
```

Or target a specific set using device groups, or list them explicitly:

```
admin@ncs(config)# devices device xr0 config interface Loopback 300
admin@ncs(config-Loopback)# ipv4 address 10.30.0.1 255.255.255.0
admin@ncs(config-Loopback)# exit
admin@ncs(config)# devices device xr1 config interface Loopback 300
admin@ncs(config-Loopback)# ipv4 address 10.30.0.2 255.255.255.0
admin@ncs(config-Loopback)# exit
admin@ncs(config)# commit
```

### 1.5 — Rollback a commit

NSO stores a rollback file for every commit:

```
# List available rollbacks
admin@ncs# show configuration rollback changes

# Roll back the last commit
admin@ncs(config)# rollback configuration
admin@ncs(config)# commit

# Roll back to a specific rollback ID (e.g. 10001)
admin@ncs(config)# rollback configuration 10001
admin@ncs(config)# commit
```

### 1.6 — Delete configuration

```
admin@ncs(config)# devices device xr0 config
admin@ncs(config-config)# no interface Loopback 100
admin@ncs(config-config)# exit
admin@ncs(config)# commit
```

### 1.7 — Dry-run (show what would be sent to device)

```
admin@ncs(config)# commit dry-run
admin@ncs(config)# commit dry-run outformat native
```

`outformat native` shows the raw CLI commands or NETCONF XML that would be sent to the device — useful for debugging.

### 1.8 — Sync after manual changes on device

If a device was changed outside of NSO:

```
# Pull device config into NSO (overwrites NSO's copy)
admin@ncs# devices device xr0 sync-from

# Push NSO's config to device (overwrites device's config)
admin@ncs# devices device xr0 sync-to
```

---

## Part 2 — Connect directly to a netsim device CLI

You can also SSH directly into a netsim device to inspect its config (bypassing NSO):

```bash
# Open IOS XR-style CLI on xr0
ncs-netsim cli-c xr0 --dir ~/nso-run-6.7/netsim
```

Inside the netsim device CLI:

```
# Show running config
xr0# show running-config

# Show interfaces
xr0# show interfaces

# Exit
xr0# exit
```

Or connect via SSH directly (use the port from `ncs-netsim list`):

```bash
# CLI port for xr0 is 10022
ssh admin@127.0.0.1 -p 10022
# password: admin
```

> **Note:** Changes made directly on the netsim device CLI are not reflected in NSO's CDB until you run `devices device xr0 sync-from`. Always prefer making changes through NSO to keep the CDB in sync.

---

## Part 3 — RESTCONF API

RESTCONF requires it to be enabled in `ncs.conf`. See [install-nso.md](install-nso.md#step-6--optional-enable-restconf-api). Default port: `8080`.

All RESTCONF requests use HTTP Basic Auth (`$NSO_ADMIN_USER:$NSO_ADMIN_PASSWORD` env vars) and the `application/yang-data+json` media type.

### 3.1 — Read device list

```bash
curl -su "${NSO_ADMIN_USER}:${NSO_ADMIN_PASSWORD}" \
  -H 'Accept: application/yang-data+json' \
  http://localhost:8080/restconf/data/tailf-ncs:devices/device \
  | python3 -m json.tool
```

### 3.2 — Read device config

```bash
# Full config for xr0
curl -su "${NSO_ADMIN_USER}:${NSO_ADMIN_PASSWORD}" \
  -H 'Accept: application/yang-data+json' \
  'http://localhost:8080/restconf/data/tailf-ncs:devices/device=xr0/config' \
  | python3 -m json.tool
```

### 3.3 — Add a loopback interface (PATCH)

`PATCH` merges your payload into the existing config:

```bash
curl -su "${NSO_ADMIN_USER}:${NSO_ADMIN_PASSWORD}" \
  -X PATCH \
  -H 'Content-Type: application/yang-data+json' \
  -H 'Accept: application/yang-data+json' \
  'http://localhost:8080/restconf/data/tailf-ncs:devices/device=xr0/config' \
  -d '{
    "tailf-ned-cisco-ios-xr:interface": {
      "Loopback": [
        {
          "id": 100,
          "ipv4": {
            "address": {
              "ip": "10.100.0.1",
              "mask": "255.255.255.0"
            }
          }
        }
      ]
    }
  }'
```

A `204 No Content` response means success.

### 3.4 — Delete an interface (DELETE)

```bash
curl -su "${NSO_ADMIN_USER}:${NSO_ADMIN_PASSWORD}" \
  -X DELETE \
  'http://localhost:8080/restconf/data/tailf-ncs:devices/device=xr0/config/tailf-ned-cisco-ios-xr:interface/Loopback=100'
```

### 3.5 — Sync-from via RESTCONF (RPC)

```bash
curl -su "${NSO_ADMIN_USER}:${NSO_ADMIN_PASSWORD}" \
  -X POST \
  -H 'Content-Type: application/yang-data+json' \
  'http://localhost:8080/restconf/operations/tailf-ncs:devices/device=xr0/sync-from'
```

### 3.6 — Discover YANG paths

The RESTCONF root tells you what modules are loaded:

```bash
curl -su "${NSO_ADMIN_USER}:${NSO_ADMIN_PASSWORD}" \
  -H 'Accept: application/yang-data+json' \
  http://localhost:8080/restconf/data/ietf-yang-library:modules-state \
  | python3 -m json.tool | grep '"name"'
```

To find the correct JSON key names for a NED's YANG nodes, check the YANG files:

```bash
ls ~/nso-6.7/packages/neds/cisco-iosxr-cli-7.76/src/yang/
# or browse NSO's built-in YANG browser:
# http://localhost:8080  → login → YANG Models
```

---

## Part 4 — NETCONF (raw)

NSO exposes NETCONF over SSH on port 2022. You can use `ncs-netsim netconf-console` or `netconf-console` (bundled with NSO) to send raw NETCONF RPCs.

### Check what capabilities are advertised

```bash
ssh -p 2022 admin@127.0.0.1 -s netconf
# password: admin
# NSO will send the <hello> with capabilities, then wait for your <hello>
# Press Ctrl-C to exit
```

### Use netconf-console (bundled tool)

```bash
# Get full NSO config
netconf-console --port 2022 --user admin --password admin \
  --get-config running

# Get device xr0 config
netconf-console --port 2022 --user admin --password admin \
  --get-config running \
  --xpath '/devices/device[name="xr0"]/config'
```

---

## Part 5 — Useful NSO CLI reference

### Configuration commands

| Command | What it does |
|---|---|
| `config` | Enter config mode |
| `show configuration` | Show staged (uncommitted) changes |
| `show configuration diff` | Show diff of staged changes |
| `commit` | Apply changes to devices |
| `commit dry-run` | Preview commit without applying |
| `commit dry-run outformat native` | Show raw device CLI/NETCONF that would be sent |
| `revert` | Discard all staged changes |
| `rollback configuration` | Roll back last commit |
| `abort` | Exit config mode, discard changes |

### Device management commands

| Command | What it does |
|---|---|
| `show devices list` | All devices with NED and admin-state |
| `show devices device * sync-state` | Sync status for all devices |
| `devices sync-from` | Pull config from all devices into NSO |
| `devices sync-to` | Push NSO config to all devices |
| `devices device xr0 sync-from` | Sync one device |
| `devices device xr0 compare-config` | Diff NSO CDB vs live device |
| `devices device xr0 check-sync` | Check if device is in sync (non-destructive) |
| `devices device xr0 ssh fetch-host-keys` | Update SSH host keys for a device |
| `devices disconnect` | Drop all open device connections |
