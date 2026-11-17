# Manual NSO Uninstall

Covers how to cleanly remove a Cisco NSO local install from macOS — stopping the daemon, deleting runtime and install directories, and cleaning up shell profile entries.

---

## Step 1 — Source the NSO environment

Before you can stop NSO, the `ncs` binary must be on `PATH`:

```bash
source ~/nso-6.7/ncsrc
```

If you have already deleted `ncsrc`, skip to Step 4 — you can kill NSO via its PID file directly (see below).

---

## Step 2 — Stop NSO

### Preferred: use the PID file

`ncs --status` can hang indefinitely if NSO is not running. Use the PID file instead:

```bash
PID_FILE="$HOME/nso-run-6.7/logs/ncs.pid"

if [[ -f "$PID_FILE" ]]; then
  pid=$(cat "$PID_FILE")
  if kill -0 "$pid" 2>/dev/null; then
    echo "NSO is running (PID $pid). Stopping..."
    cd ~/nso-run-6.7 && ncs --stop
  else
    echo "PID file exists but process is not running — already stopped."
  fi
else
  echo "No PID file found — NSO is not running."
fi
```

`kill -0 $pid` checks whether the process exists without sending a signal. It returns non-zero immediately if the process is gone.

### If ncsrc is gone (install already partially deleted)

```bash
PID_FILE="$HOME/nso-run-6.7/logs/ncs.pid"
pid=$(cat "$PID_FILE" 2>/dev/null)

if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
  kill "$pid"
  echo "Sent SIGTERM to NSO (PID $pid)"
fi
```

---

## Step 3 — Delete the runtime directory

The runtime directory contains the CDB (database), logs, config, and netsim. Delete it entirely:

```bash
rm -rf ~/nso-run-6.7
```

What is removed:
- `ncs.conf` — NSO configuration
- `ncs-cdb/` — full configuration database (all device + service config)
- `logs/` — all log files
- `state/` — NSO internal lock and state files
- `packages/` — symlinks to NED/service packages
- `netsim/` — simulated device directories (if created)

> If you want to keep the runtime (e.g. to reinstall NSO software without losing device config), skip this step.

---

## Step 4 — Delete the NSO install directory

```bash
rm -rf ~/nso-6.7
```

What is removed:
- All NSO binaries (`ncs`, `ncs_cli`, `ncs-netsim`, `ncs-setup`, etc.)
- Libraries and YANG models
- Bundled NED packages (`packages/neds/`)
- Example projects (`examples.ncs/`)
- HTML documentation (`doc/`)
- `ncsrc` environment script

---

## Step 5 — Remove shell profile entries

The install process adds a `source` line to your shell profiles. Remove it from each one.

### `~/.zprofile`

```bash
# View what's in there
grep -n 'nso\|ncsrc' ~/.zprofile

# Remove the two lines (marker comment + source line)
# Using a temp file avoids macOS sed -i portability issues
tmpfile=$(mktemp)
grep -Fv 'source "/Users/$(whoami)/nso-6.7/ncsrc"' ~/.zprofile \
  | grep -Fv '# Added by install_nso_local.sh' \
  > "$tmpfile"
mv "$tmpfile" ~/.zprofile
```

Repeat for `~/.zshrc` and `~/.bash_profile` if they were modified:

```bash
for profile in ~/.zshrc ~/.bash_profile; do
  if [[ -f "$profile" ]] && grep -q 'nso-6.7/ncsrc' "$profile"; then
    tmpfile=$(mktemp)
    grep -Fv 'source "/Users/$(whoami)/nso-6.7/ncsrc"' "$profile" \
      | grep -Fv '# Added by install_nso_local.sh' \
      > "$tmpfile"
    mv "$tmpfile" "$profile"
    echo "Cleaned: $profile"
  fi
done
```

Also remove `JAVA_HOME` and openjdk PATH entries if they were added for NSO and are no longer needed:

```bash
# Check what's there
grep -n 'JAVA_HOME\|openjdk' ~/.zprofile
```

---

## Step 6 — Verify removal

```bash
# Directories gone
ls ~/nso-6.7  2>/dev/null && echo "STILL EXISTS" || echo "Removed"
ls ~/nso-run-6.7 2>/dev/null && echo "STILL EXISTS" || echo "Removed"

# Commands no longer available (after opening a new shell)
which ncs 2>/dev/null && echo "STILL ON PATH" || echo "Removed from PATH"
```

Open a new terminal (or run `exec zsh`) for the PATH changes to take effect.

---

## Selective removal (keep some parts)

### Keep the runtime, remove only the software install

Useful when you want to upgrade NSO but preserve your device config and CDB:

```bash
# Stop NSO first (see Step 2)
cd ~/nso-run-6.7 && ncs --stop

# Remove only the install dir
rm -rf ~/nso-6.7
```

Then install the new version and point `ncs-setup` (or just `ncs`) at the existing runtime dir — the CDB data is preserved.

### Keep the install, remove only the runtime instance

Useful when starting fresh with a clean CDB:

```bash
cd ~/nso-run-6.7 && ncs --stop
rm -rf ~/nso-run-6.7

# Recreate a clean runtime
ncs-setup --dest ~/nso-run-6.7
cd ~/nso-run-6.7 && ncs
```

### Remove netsim only (keep NSO and CDB)

```bash
# Stop netsim devices
ncs-netsim stop --dir ~/nso-run-6.7/netsim

# Remove netsim directory
rm -rf ~/nso-run-6.7/netsim

# Remove device definitions from CDB (in NSO CLI)
ncs_cli -u "${NSO_ADMIN_USER}" -C
admin@ncs# no devices device xr0
admin@ncs# no devices device xr1
admin@ncs# no devices device xr2
admin@ncs# commit
```

---

## Quick full removal (one block)

```bash
source ~/nso-6.7/ncsrc

# Stop NSO if running
pid=$(cat ~/nso-run-6.7/logs/ncs.pid 2>/dev/null || echo "")
if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
  cd ~/nso-run-6.7 && ncs --stop
fi

# Delete directories
rm -rf ~/nso-run-6.7
rm -rf ~/nso-6.7

# Clean shell profiles
for profile in ~/.zprofile ~/.zshrc ~/.bash_profile; do
  [[ -f "$profile" ]] || continue
  grep -q 'nso-6.7/ncsrc' "$profile" || continue
  tmpfile=$(mktemp)
  grep -Fv "source \"$HOME/nso-6.7/ncsrc\"" "$profile" \
    | grep -Fv '# Added by install_nso_local.sh' \
    > "$tmpfile"
  mv "$tmpfile" "$profile"
  echo "Cleaned: $profile"
done

echo "Done. Open a new terminal for PATH to update."
```
