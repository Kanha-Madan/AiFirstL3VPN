# Netsim Devices — Create and Manage

Covers how to create simulated device networks with `ncs-netsim`, load them into NSO, and manage them during development.

Assumes a NED is already installed. See [install-ned.md](install-ned.md).  
For connecting and pushing config to devices, see [configure-devices.md](configure-devices.md).

---

## What is netsim?

`ncs-netsim` creates lightweight simulated devices that run locally. Each device:
- Speaks the same NETCONF/CLI protocol as real hardware
- Uses the NED's YANG models — so the config schema is identical to a real device
- Gets its own SSH port, NETCONF port, and IPC port
- Lives as a directory under `~/nso-run-6.7/netsim/`

You never need real hardware for NSO development — netsim covers the full config push/pull loop.

---

## Prerequisites

```bash
source ~/nso-6.7/ncsrc
export JAVA_HOME="/opt/homebrew/opt/openjdk@21"
```

Make sure the NED is installed and NSO has loaded it:

```
admin@ncs# show packages package cisco-iosxr-cli-7.76
```

If it's not listed, install the NED first and run `packages reload`. See [install-ned.md](install-ned.md).

---

## Part 1 — Create a netsim network

### First time — create from scratch

```bash
NED_PKG_DIR="$HOME/nso-6.7/packages/neds/cisco-iosxr-cli-7.76"
NETSIM_DIR="$HOME/nso-run-6.7/netsim"
PREFIX="xr"
COUNT=3

ncs-netsim create-network "$NED_PKG_DIR" "$COUNT" "$PREFIX" --dir "$NETSIM_DIR"
```

Creates `xr0`, `xr1`, `xr2` under `~/nso-run-6.7/netsim/xr/`.

### Add more devices later

```bash
ncs-netsim add-to-network "$NED_PKG_DIR" 2 "$PREFIX" --dir "$NETSIM_DIR"
```

Continues numbering from where it left off — creates `xr3`, `xr4`.

### Common device prefix conventions

| NED name contains | Prefix |
|---|---|
| `iosxr` | `xr` |
| `ios-cli` | `ios` |
| `nx-cli` | `nx` |
| `asa-cli` | `asa` |

---

## Part 2 — Start devices and verify

```bash
ncs-netsim start --dir "$NETSIM_DIR"
```

Expected output:
```
DEVICE xr0 OK STARTED
DEVICE xr1 OK STARTED
DEVICE xr2 OK STARTED
```

`FAIL` with "address already in use" means those devices are already running — safe to ignore.

List all devices and their assigned ports:

```bash
ncs-netsim list --dir "$NETSIM_DIR"
```

```
name=xr0 netconf=12022 snmp=11022 ipc=5010 cli=10022 dir=.../netsim/xr/xr0
name=xr1 netconf=12023 snmp=11023 ipc=5011 cli=10023 dir=.../netsim/xr/xr1
name=xr2 netconf=12024 snmp=11024 ipc=5012 cli=10024 dir=.../netsim/xr/xr2
```

| Port type | Starting port | Protocol |
|---|---|---|
| CLI | 10022 | SSH |
| NETCONF | 12022 | SSH |
| SNMP | 11022 | UDP |
| IPC (internal) | 5010 | TCP |

---

## Part 3 — Load devices into NSO

### Step 1 — Generate device init XML

`ncs-xml-init` produces a `<devices>` XML document with one `<device>` entry per netsim device, pre-populated with address, port, SSH host keys, authgroup, and NED ID.

```bash
ncs-netsim --dir "$NETSIM_DIR" ncs-xml-init \
  > ~/nso-run-6.7/ncs-cdb/netsim-devices.xml
```

> **Flag order matters:** `--dir` must come *before* the subcommand. `ncs-netsim ncs-xml-init --dir X` silently fails because the tool ignores `--dir` when it appears after the subcommand.

Confirm all devices are in the XML:

```bash
grep '<name>' ~/nso-run-6.7/ncs-cdb/netsim-devices.xml
```

### Step 2 — Load into the running NSO CDB

```bash
cd ~/nso-run-6.7
ncs_load -l -m ncs-cdb/netsim-devices.xml
```

Flags:
- `-l` — load into live (running) NSO
- `-m` — merge into existing CDB (additive, not replace)

If NSO is not running, leave the XML in `ncs-cdb/` and NSO will load it on next start.

### Step 3 — Fetch SSH host keys

```
admin@ncs# devices fetch-ssh-host-keys
```

Or per device:
```
admin@ncs# devices device xr0 ssh fetch-host-keys
admin@ncs# devices device xr1 ssh fetch-host-keys
admin@ncs# devices device xr2 ssh fetch-host-keys
```

This step is required whenever:
- Devices are first created
- The netsim network is destroyed and recreated (new SSH keys are generated)
- Devices are restarted after a long pause

### Step 4 — Sync config from devices

```
admin@ncs# devices sync-from
```

Expected output:
```
sync-result {
    device xr0
    result true
}
sync-result {
    device xr1
    result true
}
```

`result false` with "Could not verify ssh-rsa host key" → run `fetch-ssh-host-keys` first.

---

## Part 4 — Daily dev loop

### Stop and start

```bash
# Stop all netsim devices (e.g. before shutting down your laptop)
ncs-netsim stop --dir ~/nso-run-6.7/netsim

# Start them again next session
ncs-netsim start --dir ~/nso-run-6.7/netsim
```

After restarting devices that generate new SSH keys (this doesn't happen every restart):

```
admin@ncs# devices fetch-ssh-host-keys
admin@ncs# devices sync-from
```

### Connect directly to a device CLI

```bash
# Open IOS XR-style CLI on xr0 (bypasses NSO)
ncs-netsim cli-c xr0 --dir ~/nso-run-6.7/netsim

# Or via SSH using the port from ncs-netsim list
ssh admin@127.0.0.1 -p 10022   # password: admin
```

> Changes made directly on the device are not reflected in NSO until `devices device xr0 sync-from` is run. Always prefer making changes through NSO.

---

## Part 5 — Destroy and recreate

During development you may want to wipe all devices and start fresh (e.g. corrupt config, testing clean state).

### Stop and remove all devices

```bash
ncs-netsim stop --dir ~/nso-run-6.7/netsim
rm -rf ~/nso-run-6.7/netsim
```

Remove device definitions from NSO CDB:

```
admin@ncs# config
admin@ncs(config)# no devices device xr0
admin@ncs(config)# no devices device xr1
admin@ncs(config)# no devices device xr2
admin@ncs(config)# commit
```

Or delete the old XML and let NSO reload without those entries on restart:

```bash
rm ~/nso-run-6.7/ncs-cdb/netsim-devices.xml
```

### Recreate from scratch

```bash
NED_PKG_DIR="$HOME/nso-6.7/packages/neds/cisco-iosxr-cli-7.76"
NETSIM_DIR="$HOME/nso-run-6.7/netsim"

ncs-netsim create-network "$NED_PKG_DIR" 3 xr --dir "$NETSIM_DIR"
ncs-netsim start --dir "$NETSIM_DIR"

ncs-netsim --dir "$NETSIM_DIR" ncs-xml-init \
  > ~/nso-run-6.7/ncs-cdb/netsim-devices.xml

cd ~/nso-run-6.7
ncs_load -l -m ncs-cdb/netsim-devices.xml
```

Then in NSO CLI:
```
admin@ncs# devices fetch-ssh-host-keys
admin@ncs# devices sync-from
```

---

## Using the netsim_devices.sh script

The `netsim_devices.sh` script wraps all of the above. It's faster for the dev loop than running individual commands.

```bash
# Create 3 devices and load into NSO
./scripts/netsim_devices.sh --create \
  --ned-dir ~/nso-6.7/packages/neds/cisco-iosxr-cli-7.76 \
  --devices 3 --load-into-nso

# Fetch SSH keys
./scripts/netsim_devices.sh --fetch-keys

# Sync from devices
./scripts/netsim_devices.sh --sync-from

# Stop all devices
./scripts/netsim_devices.sh --stop

# Start all devices
./scripts/netsim_devices.sh --start

# Destroy everything (with confirmation prompt)
./scripts/netsim_devices.sh --destroy

# Destroy without prompt
./scripts/netsim_devices.sh --destroy -y
```

---

## Full netsim command reference

```bash
# Create network (first NED)
ncs-netsim create-network <NED_PKG_DIR> <count> <prefix> --dir <netsim-dir>

# Add devices to existing network
ncs-netsim add-to-network <NED_PKG_DIR> <count> <prefix> --dir <netsim-dir>

# Start / stop / restart all devices
ncs-netsim start   --dir <netsim-dir>
ncs-netsim stop    --dir <netsim-dir>
ncs-netsim restart --dir <netsim-dir>

# List devices and ports
ncs-netsim list --dir <netsim-dir>

# Check which devices are alive
ncs-netsim is-alive --dir <netsim-dir>

# Open IOS XR CLI on a device
ncs-netsim cli-c xr0 --dir <netsim-dir>

# Connect via NETCONF
ncs-netsim netconf-console xr0 --dir <netsim-dir>

# Generate NSO device init XML (--dir MUST come before the subcommand)
ncs-netsim --dir <netsim-dir> ncs-xml-init > ncs-cdb/netsim-devices.xml

# Delete entire netsim setup
ncs-netsim delete-network --dir <netsim-dir>
```
