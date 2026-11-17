---
name: af-nso-manage-package
description: 'Cisco NSO package lifecycle management. Use for: create NSO package, scaffold package, create service package, create NED package, ncs-make-package, build package, load package, install package into NSO, remove package, delete package, unload package, packages reload, packages redeploy, package dev loop, YANG models, NSO service skeleton, NSO python package, NSO template package, generate service from native CLI config, load-native-config, config to YANG, native config to NSO template, service package from device config, interface enumeration, Python service callbacks, vars.add, end-to-end service test. Covers: ncs-make-package options, package structure, build with make, symlink into runtime, packages reload, redeploy workflow, safe package removal.'
argument-hint: 'package type and name — e.g. "create a python service package called vlan-svc", "scaffold a template-only package", "create a NETCONF NED for acme-router", "generate a service from this IOS-XR config"'
license: Proprietary
---

# NSO Package Management

Covers the full package lifecycle: scaffold → build → install → edit → redeploy → remove.  
Also covers generating a complete service package from native CLI device configuration.

> Script: [./scripts/manage_package.sh](./scripts/manage_package.sh)

---

## Generate Service Package from Native Config

When you have native CLI device configuration and want to produce a full, tested NSO service package (YANG + Python callbacks + XML template), follow the guided workflow in **[references/service-from-config.md](./references/service-from-config.md)**.

> **Pipeline role:** In the canonical package-development pipeline this workflow is **Stage 4**, normally invoked by **af-nso-spec-orchestrator** with the concrete native config rendered from the spec (instance-variable tokens already resolved). It also runs standalone for a quick package from a config you already have. For a **brand-new service with no config**, start at **af-nso-service-requirements** (Stage-1 elicitation) → **af-nso-spec-document** — not here.

The workflow covers Steps 0–11:
0. **Input detection** — accepts concrete config from the orchestrator, or a requirements doc / per-role config files if present; the latter unlocks multi-device YANG patterns (`role-lists`, `endpoint-list`)
1. Save the input config to a file
2. Parse config → identify service parameters vs. static lines; **2b: Interface type coverage check** *(mandatory — never skip)*: scans for `interface`, `GigabitEthernet`, `TenGigE`, `Bundle-Ether`, etc.; builds an enumeration leaf in YANG, conditional `<?if?>` blocks in the template, and per-type test runs
3. Design the YANG service model (types, `mandatory true`, `tailf:info`; flat / role-lists / endpoint-list patterns)
4. Verify NSO is running; locate `<ncs-run-dir>`
5. Scaffold the package with `manage_package.sh`
6. Ensure a matching NETSIM device exists (creates one if needed)
7. Generate authoritative XML template via `load-native-config` through the real NED (with multi-role merging for multi-device services)
8. Write Python service callbacks with correct `vars.add()` mappings (with per-endpoint iteration for multi-device patterns)
9. Update package skeleton files (YANG, template, Python)
10. Build + reload with `manage_package.sh --build-only --reload-packages`; iterate until `oper-status up`
11. End-to-end test: dry-run → commit → `show running-config` verify → cleanup (all roles and interface types)

> **Key rule:** always use `load-native-config` output as the authoritative template source — never hand-author device config XML.

---

## Create a New Package (Scaffold + Build + Install)

```bash
scripts/manage_package.sh my-svc \
  --type python-and-template \
  --reload-packages
```

This single command:
1. Runs `ncs-make-package` → creates `packages/my-svc/`
2. Runs `make -C packages/my-svc/src all` (builds YANG + code)
3. Symlinks `packages/my-svc` → `~/nso-run-6.7/packages/my-svc`
4. Runs `packages reload` in NSO CLI

### All options

| Option | What it does |
|---|---|
| `--type TYPE` | Package skeleton type (default: `python-and-template`) |
| `--dest DIR` | Output path (default: `packages/<name>`) |
| `--augment PATH` | Augment service model under PATH (e.g. `/ncs:services`) |
| `--reload-packages` | Run `packages reload` in NSO CLI after symlinking |
| `--redeploy` | Run `packages package <name> redeploy` (faster, no YANG reload) |
| `--build-only` | Skip scaffold; build + install an existing package |
| `--remove` | Unload from NSO and remove symlink (safe removal) |
| `--delete-source` | Used with `--remove`: also delete `packages/<name>/` source |
| `--install-dir PATH` | Override auto-detected `~/nso-[0-9]*` install dir |
| `--runtime-dir PATH` | Override auto-detected `~/nso-run-*` runtime dir |
| `-y / --yes` | Skip confirmation prompts |

### Common package types

| `--type` | Creates |
|---|---|
| `python-and-template` | Python service + XML template (recommended default) |
| `template` | XML device template only (no Python code) |
| `python` | Python service only (no template) |
| `java-and-template` | Java service + XML template |
| `nano-python-and-template` | Nano service with plan stages + Python + template |

See [references/package-types.md](./references/package-types.md) for NETCONF NED, SNMP NED, and generic NED options.

---

## Remove a Package

```bash
scripts/manage_package.sh my-svc --remove
```

To also delete the source from `packages/`:

```bash
scripts/manage_package.sh my-svc --remove --delete-source -y
```

### What the script does (safe order)

1. Removes the **symlink** from `~/nso-run-6.7/packages/my-svc`
2. Runs `packages reload` in NSO CLI — NSO unloads the package and cleans up its schema
3. With `--delete-source`: deletes `packages/my-svc/` source directory

> **Why order matters:** If you delete `packages/my-svc/` first, the symlink becomes dangling and NSO errors on the next `packages reload`. Always remove the symlink and reload NSO *before* deleting the source.

> **If you already deleted from `packages/` directly:** the symlink in `~/nso-run-6.7/packages/` is now dangling. Fix it:
> ```bash
> rm ~/nso-run-6.7/packages/my-svc          # remove the dangling symlink
> ncs_cli -u "${NSO_ADMIN_USER}" -C <<< 'packages reload'  # let NSO clean up
> ```

---

## Dev Loop — Rebuild and Redeploy an Existing Package

After editing YANG models or Python/templates in `packages/my-svc/`:

### YANG model changed (`.yang` files):

```bash
scripts/manage_package.sh packages/my-svc \
  --build-only \
  --reload-packages
```

### Only Python or templates changed (no YANG changes):

```bash
scripts/manage_package.sh packages/my-svc \
  --build-only \
  --redeploy
```

> `--redeploy` is faster — restarts only the Python VM and reloads templates without a full schema reload.

---

## Package Structure (What Gets Created)

```
packages/my-svc/
├── package-meta-data.xml   # Package metadata — edit name/vendor/version here
├── src/
│   ├── Makefile            # Build file
│   └── yang/
│       └── my-svc.yang     # Service YANG model — primary edit target
├── templates/
│   └── my-svc-template.xml # Device config template (python-and-template)
├── python/
│   └── my_svc/
│       └── main.py         # Python service code (python-and-template)
└── test/
    └── ...                 # Auto-generated test structure
```

**Key files to edit:**
- `src/yang/my-svc.yang` — YANG data model for service inputs
- `templates/my-svc-template.xml` — device config to push (references YANG variables)
- `python/my_svc/main.py` — Python service logic
- `package-meta-data.xml` — update `<name>`, `<vendor>`, `<package-version>`

### Python service callback rules

Every `{/leaf-name}` token in the XML template **must** have a matching `vars.add()` call. Every YANG leaf referenced in the template must appear exactly once:

```python
import ncs
from ncs.application import Service

class ServiceCallbacks(Service):
    @Service.create
    def cb_create(self, tctx, root, service, proplist):
        self.log.info(f'Service create: {service._path}')
        vars = ncs.template.Variables()
        vars.add('DEVICE',       service.device)
        vars.add('VLAN_ID',      service.vlan_id)
        # add one vars.add() per {/leaf} token used in the template
        template = ncs.template.Template(service)
        template.apply('my-svc-template', vars)

class Main(ncs.application.Application):
    def setup(self):
        self.log.info('Main RUNNING')
        self.register_service('my-svc-servicepoint', ServiceCallbacks)
    def teardown(self):
        self.log.info('Main FINISHED')
```

> Do **not** add `vars.add()` for leaves that are not referenced in the template.  
> Template variable names in `{/leaf-name}` must match the `vars.add('LEAF_NAME', ...)` key (uppercased by convention).

---

## Key Facts

### What the script does (step by step)
1. Auto-detects `~/nso-[0-9]*` (install) and `~/nso-run-*` (runtime) dirs
2. Sources `ncsrc` with `set +u` / `set -u` guard
3. Runs `ncs-make-package --service-skeleton <type> --dest packages/<name> <name>` (scaffold only)
4. Runs `make -C packages/<name>/src all` (build)
5. Creates `~/nso-run-6.7/packages/<name>` → symlink to `packages/<name>` in project root
6. If `--reload-packages`: runs `packages reload` in NSO CLI
7. If `--redeploy`: runs `packages package <name> redeploy` in NSO CLI

### Symlink approach
Package source lives in `packages/` (git-tracked). The runtime `~/nso-run-6.7/packages/` holds a **symlink** to it. Always edit files under `packages/`, not inside the runtime dir.

### packages reload vs redeploy

| Situation | Flag |
|---|---|
| YANG model changed (`.yang`, `.fxs`) | `--reload-packages` |
| Only Python or template changed | `--redeploy` |
| New package added for the first time | `--reload-packages` |
| Debugging (force full reload) | `--reload-packages` then run `packages reload force` in CLI |

### Check if NSO is running
```bash
kill -0 $(cat ~/nso-run-6.7/logs/ncs.pid) 2>/dev/null && echo "running" || echo "stopped"
```

---

## Verify Package is Loaded

```
admin@ncs# show packages package my-svc
NAME     PACKAGE VERSION  OPERATIONAL STATUS  ERROR INFO
-------  ---------------  ------------------  ----------
my-svc   1.0              up
```

If `OPERATIONAL STATUS` is `down`, read the log and fix-rebuild-reload:
```bash
tail -50 ~/nso-run-6.7/logs/ncs-python-vm-my-svc.log
tail -50 ~/nso-run-6.7/logs/ncserr.log
# fix the error, then:
scripts/manage_package.sh packages/my-svc \
  --build-only --reload-packages
```
Iterate until `oper-status up`.

### End-to-end service test (after package is up)

```bash
# 1. Dry-run — inspect native CLI output; must be non-empty and match expected config
ncs_cli -Cu admin << 'EOF'
config
my-svc test-instance device <testDevice>
leaf1 value1
leaf2 value2
commit dry-run outformat native
EOF

# 2. Commit
ncs_cli -Cu admin << 'EOF'
config
my-svc test-instance device <testDevice>
leaf1 value1
commit
EOF

# 3. Verify config was pushed to the device
ncs_cli -Cu admin << 'EOF'
show running-config devices device <testDevice> config
EOF

# 4. Cleanup
ncs_cli -Cu admin << 'EOF'
config
no my-svc test-instance
commit
EOF
```

If using interface type variants (from the service-from-config workflow), run the dry-run for **every supported interface type** — all must produce non-empty correct output before committing.

> If dry-run is empty or incorrect: fix YANG / template / Python, rebuild with `--build-only --reload-packages`, and retry.

---

## Reference Docs

- [references/package-types.md](./references/package-types.md) — all package type options, YANG patterns, template variables, common errors
- [references/service-from-config.md](./references/service-from-config.md) — full 11-step workflow: native CLI config → working tested NSO service package
- [scripts/manage_package.sh](./scripts/manage_package.sh) — full lifecycle: scaffold, build, symlink, reload, remove
