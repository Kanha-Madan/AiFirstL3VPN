---
name: af-nso-version-switch
description: 'Switch the active local Cisco NSO installation to a requested version. Use for: install a specific NSO version, switch to 6.4.1, switch to 6.5.1, create a fresh runtime for a different NSO release, force a requested NSO version instead of reusing an older installed version.'
argument-hint: 'target-version — e.g. "6.4.1" or "6.5.1"'
---

# Switch NSO Version

Use this skill whenever the project or service spec requires a specific NSO version and the local machine already has a different version installed.

## Critical Rule

If a target version is specified in the user request, project spec, or generated artifact, that version is authoritative.

Do not do this:
- detect any existing `~/nso-*` install and silently reuse it
- pick the newest or newest-available version just because it is already present
- create or use a runtime that does not match the required NSO version

Do this instead:
1. stop any running NSO instance that is not the target runtime
2. fetch and install the exact requested NSO version
3. create a new runtime directory for that exact version
4. source the matching `ncsrc` file and start that runtime
5. persist the active version to the shell profiles only after the new runtime is confirmed

## Commands

```bash
# Switch to a required version, e.g. 6.4.1
bash nso-code-template/scripts/switch_nso_version.sh 6.4.1 --fetch --start --verify --persist-env

# Switch to a newer version, e.g. 6.5.1
bash nso-code-template/scripts/switch_nso_version.sh 6.5.1 --fetch --start --verify --persist-env
```

## Expected behavior

The script does the following:
- resolves the exact NSO installer for the requested version
- stops any currently running `ncs` instance to avoid mixing versions
- installs the target version under `~/nso-<version>`
- creates a fresh runtime under `~/nso-run-<version>`
- starts the target runtime only after the new install is available
- updates shell profile entries so future shells source the requested `ncsrc`
- verifies the resulting install and runtime

## When to use it

Use this skill whenever:
- the spec file requires NSO `6.4.1` but `6.5.1` already exists locally
- the user says “switch NSO to version X”
- a package build or validation requires a specific release and the current active runtime is different
- the user needs to move from one local NSO version to another without reusing stale runtime state

## Important implementation rule for AIFirst primitives

AIFirst must treat the target version as a required input and use it as the installation key. The command must never be equivalent to “use whatever NSO is already installed.” If the active version differs, install the requested one and start the matching runtime instead.
