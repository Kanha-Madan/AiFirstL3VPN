---
name: af-nso-preflight
description: 'Verify the NSO developer environment is ready BEFORE any NSO work. Use first for: check prerequisites, is NSO installed, is NSO running, environment check, preflight, setup check, RESTCONF up, keychain creds for NED downloads, "let me check the prerequisites". Read-only checks; remediates gaps only by delegating to af-nso-local-install (install/start). Never edits the AI primitives.'
argument-hint: 'usually none — runs a fast read-only environment readiness check'
license: Proprietary
---

# NSO Environment Preflight

A fast, **read-only** gate that confirms the developer environment is ready
before any NSO task. Run it **first** for every NSO request that will touch the
environment (build a package, install a NED, manage devices, install MCP, run
the spec pipeline). Announce it plainly:

> "Let me check the prerequisites first…"

If everything is ready, say so briefly and continue. If a gap is found, **report
it and offer to bring the environment up** by delegating to
[af-nso-local-install](../af-nso-local-install/SKILL.md) — do not silently start
development on a broken environment. For a pure conceptual question that needs no
environment (e.g. "what is a NED?"), you may skip preflight.

> Script: [./scripts/preflight_check.sh](./scripts/preflight_check.sh) — runs all
> checks read-only and prints a per-check report plus a final
> `PREFLIGHT: READY` / `PREFLIGHT: GAPS=<n>` line (exit `0` ready, `3` gaps).

## Run the check

```bash
bash scripts/preflight_check.sh
```

It verifies, without changing anything:

| # | Check | How (read-only) |
|---|---|---|
| 1 | **NSO installed** | `ncs` on PATH, or `~/nso-<ver>/bin/ncs` |
| 2 | **NSO running** | PID file `~/nso-run-<ver>/logs/ncs.pid` (`kill -0`) or `pgrep -f "conffile …/ncs.conf"` — **never `ncs --status`, which hangs when NSO is down** |
| 3 | **RESTCONF reachable** | `curl -m4 http://localhost:8080/restconf` → 2xx/401 = up |
| 4 | **NED-download creds** | macOS Keychain entry for `dl.tail-f.com` (used by `fetch_ned.sh`) |

## Remediate gaps (announce, confirm, then delegate)

Resolve gaps in this order; announce each and confirm before install/start:

1. **NSO not installed** → delegate to **af-nso-local-install** to install and
   start with RESTCONF (`install_nso_local.sh … --start --enable-restconf`).
2. **NSO installed but not running** → start it from the runtime dir
   (`cd ~/nso-run-<ver> && ncs`), or `af-nso-local-install … --start`.
3. **RESTCONF not reachable** → enable it via
   **af-nso-local-install** (`--enable-restconf`) and restart NSO.
4. **No Keychain credentials** → none needed until the first NED/MCP download;
   `fetch_ned.sh` prompts once and stores them securely in the Keychain (never on
   disk). Only pre-store if the user wants downloads to be non-interactive later.

After remediation, re-run `preflight_check.sh` to confirm `PREFLIGHT: READY`
before proceeding with the original request.

## Constraints

- **Read-only checks.** The script never installs, starts, stops, or edits
  anything. All bring-up happens by delegating to af-nso-local-install.
- **Announce and confirm** before any install or start — do not silently mutate
  the environment.
- **Never `ncs --status`** for the running check — it blocks indefinitely when
  NSO is down. Use the PID-file / `pgrep` approach the script uses.
- **Do not modify the AI primitives** (installed skills, instructions, or agent
  prompts under `.github/`, `.cursor/`, or `.claude/`). They are managed by the
  aifirst CLI; if one looks wrong, tell the user instead of editing it.
