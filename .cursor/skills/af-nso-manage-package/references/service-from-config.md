# Generate NSO Service Package from Native CLI Config

Full workflow (Steps 0–11) to produce a complete, tested NSO service package — YANG model, XML device template, and Python service callbacks — using a live NSO instance to generate the template through the real NED. Supports both single-device (flat YANG) and multi-device (role-lists / endpoint-list) service patterns.

**Inputs required before starting:**
- `device-type` — vendor and platform (e.g. `cisco-iosxr`, `cisco-ios-xe`, `juniper-junos`)
- `config` — native CLI configuration, inline text, a single file path, or a list of `role=<path>` pairs for multi-device services (e.g. `pe=input-configs/svc-pe.cfg ce=input-configs/svc-ce.cfg`). In handover mode this is pre-filled from the requirements doc.
- `service-name` *(optional)* — infer from the config's feature if not provided
- `requirements-doc` *(optional)* — path to a `<service-name>-requirements.md` file produced by the `af-nso-service-requirements` skill. When provided, enables **handover mode** (Step 0) which pre-fills all inputs and unlocks multi-device YANG patterns.

Ask for any missing required inputs before proceeding.

---

## Step 0 — Detect Handover from af-nso-service-requirements

Check whether a `requirements-doc` argument was passed **or** a file matching `input-configs/<service-name>-requirements.md` exists in `<ncs-run-dir>`.

> **How this is invoked:** In the pipeline, **af-nso-spec-orchestrator** (Stage 4)
> drives this workflow with the concrete native config rendered from the spec —
> instance-variable tokens already resolved. Direct invocation is also supported:
> a `requirements-doc` (from af-nso-service-requirements, which unlocks multi-role
> patterns) or a config you already have. It is **not** the front door for a
> brand-new service with no config — that starts at af-nso-service-requirements
> → af-nso-spec-document.

**If a requirements doc is present (handover mode):**

1. Read the requirements doc and extract:
   - Service name, target NED/device type
   - Confirmed YANG pattern (`flat`, `role-lists`, or `endpoint-list`)
   - Parameter classification table (service-level / per-device / per-role)
   - List of per-role config file paths (from the handoff instructions section of the doc)

2. Print a summary of what was found:
   > "Handover from af-nso-service-requirements detected. Service: `<name>`, NED: `<ned>`, YANG pattern: `<pattern>`, config files: `[<role> → <path>, ...]`"

3. Ask: **"Ready to start implementation? (yes/no)"** — wait for an explicit answer. Do not proceed without it.

4. **If yes**: pre-fill all Step 1 inputs from the requirements doc; set `<inputConfigFiles>` to the ordered list of per-role config paths; record `<yang-pattern>` from the doc; proceed to Step 1.

5. **If no**: halt and inform the user they can re-invoke this workflow when ready.

**If no requirements doc is present (standard mode):**
Skip this step and proceed with Step 1 as normal. All single-device steps apply unchanged.

> In standard mode the workflow behaves identically to its previous behaviour. All multi-device extensions in Steps 3, 7, 8, and 11 are activated only when `<yang-pattern>` is `role-lists` or `endpoint-list`.

---

## Step 1 — Save the Input Configuration to a File

If the config was supplied as inline text, save it to a file so later steps can reference it:

```bash
mkdir -p <ncs-run-dir>/input-configs
cat > <ncs-run-dir>/input-configs/<service-name>.cfg << 'EOF'
<paste native CLI config here>
EOF
```

- If config was already supplied as a file path, note it as `<inputConfigFile>` and skip writing.
- Confirm the absolute path of `<inputConfigFile>` before proceeding.

---

## Step 2 — Parse and Annotate the Config

Read `<inputConfigFile>` and identify:
- The network feature being configured (e.g. BGP neighbor, VRF, MPLS L3VPN, QoS policy)
- **Variable parameters** that will become service inputs (IP addresses, route-targets, AS numbers, policy names, VLANs, etc.)
- **Static / boilerplate lines** that belong in the XML template verbatim

Produce an annotated summary listing each identified service parameter and its role.

**Before moving on:** explicitly state whether the config contains any interface configuration. This output is required — do not skip or omit it.

---

## Step 2b — Interface Type Coverage Check *(MANDATORY — never skip)*

> **This step is not optional.** Execute it for every config, regardless of whether you think interfaces are present. Skipping it and discovering interface types later requires rebuilding YANG, template, and Python from scratch.

Scan `<inputConfigFile>` for any occurrence of interface-related keywords, including but not limited to:
`interface`, `GigabitEthernet`, `TenGigE`, `HundredGigE`, `FortyGigE`, `Bundle-Ether`, `Loopback`, `tunnel-ip`, `BVI`, `Management`, `port-channel`, `vlan`

**Case A — No interface keywords found:**

State: *"No interface configuration detected. Step 2b complete."* Then proceed to Step 3.

**Case B — Interface keywords found:**

1. **List every interface type** with its exact identifier from the config (e.g. `GigabitEthernet0/0/0/1.100`, `Loopback0`). List each one — do not summarise.

2. **Stop and ask the user:**
   > "The input config uses the following interface type(s): **[list]**. Should the service also support additional types (e.g. TenGigE, HundredGigE, Bundle-Ether, Loopback)? List any additions, or reply **no** to support only the types above."

3. **Wait for an explicit answer.** Do not infer an answer or default to `no`.

4. **Build the supported interface type list**: original types from config + any the user added.

5. **Create a per-interface config file** for every supported type. Copy `<inputConfigFile>` and substitute only the interface keyword. Save each as:
   ```
   <ncs-run-dir>/input-configs/<service-name>-<interface-type>.cfg
   ```
   Record the complete list of `(interface-type → file path)` pairs — this list drives Steps 7, 9, and 11.

6. **Propagate the supported interface types into all downstream steps:**
   - **YANG (Step 3)**: model interface type as a `leaf` with `type enumeration` (one enum per supported type); add `tailf:info` listing all supported values
   - **XML template (Step 7)**: load each per-interface config file via NSO; merge payloads using `<?if {interface-type = 'X'}?>...<?end?>` — omitting any type is a bug
   - **Python (Step 8)**: add `vars.add('INTERFACE_TYPE', service.interface_type)` and document all supported values in a comment
   - **Test (Step 11)**: run a separate `commit dry-run` for **each** supported interface type — all must produce correct non-empty output

   **Multi-config mode** (handover from af-nso-service-requirements with multiple role configs): run Steps 2 and 2b independently for **each** per-role config file. Accumulate all interface types discovered across all roles into one combined supported-type list. This list drives the interface-type enumeration in Step 3 and the per-role/per-interface XML merging in Step 7.

---

## Step 3 — Design the YANG Service Model

> **Gate:** Step 2b must be complete and its output stated before entering this step.

Design a `tailf-ncs:servicepoint` module based on the extracted parameters:

- Namespace: `http://example.com/nso/<service-name>`
- Module name: `<service-name>`
- Include a `devices` list keyed by `device` (leafref to `/ncs:devices/ncs:device/ncs:name`)
- Model each service parameter as a typed leaf or list
- Use appropriate YANG base types: `string`, `inet:ipv4-address`, `inet:as-number`, `uint32`, etc.
- For interface types (from Step 2b): `type enumeration` with one `enum` per supported type
- `mandatory true` for required parameters; `default` for optional ones
- `tailf:info` description on every node

**Multi-device YANG patterns** — apply the appropriate pattern based on `<yang-pattern>`. For the `flat` pattern (single device, no additional managed roles) use the standard single-device example below unchanged. For multi-device patterns, use `role-lists` or `endpoint-list` as specified.

**Pattern `flat` — single device (default for standard mode):**

```yang
module my-svc {
  namespace "http://example.com/nso/my-svc";
  prefix my-svc;

  import ietf-inet-types { prefix inet; }
  import tailf-common   { prefix tailf; }
  import tailf-ncs      { prefix ncs; }

  list my-svc {
    key name;
    uses ncs:service-data;
    ncs:servicepoint "my-svc-servicepoint";

    leaf name {
      tailf:info "Service instance name";
      type string;
    }

    leaf device {
      tailf:info "Target device";
      mandatory true;
      type leafref {
        path "/ncs:devices/ncs:device/ncs:name";
      }
    }

    leaf interface-type {
      tailf:info "Interface type — supported: GigabitEthernet, TenGigE, Bundle-Ether";
      mandatory true;
      type enumeration {
        enum GigabitEthernet;
        enum TenGigE;
        enum Bundle-Ether;
      }
    }

    leaf interface-id {
      tailf:info "Interface identifier, e.g. 0/0/0/1.100";
      mandatory true;
      type string;
    }

    // add remaining service parameter leaves here
  }
}
```

**Pattern `role-lists` — separate list per device role** (when PE and CE config structures differ significantly):

```yang
list <service-name> {
  key name;
  uses ncs:service-data;
  ncs:servicepoint "<service-name>-servicepoint";
  leaf name { type string; }
  leaf <common-param> { type <type>; mandatory true; tailf:info "..."; }
  list pe {
    key device;
    leaf device { type leafref { path "/ncs:devices/ncs:device/ncs:name"; } mandatory true; }
    leaf interface-type { type enumeration { /* PE interface types from Step 2b */ } mandatory true; }
    leaf <pe-param> { type <type>; mandatory true; tailf:info "..."; }
  }
  list ce {
    key device;
    leaf device { type leafref { path "/ncs:devices/ncs:device/ncs:name"; } mandatory true; }
    leaf <ce-param> { type <type>; mandatory true; tailf:info "..."; }
  }
}
```

**Pattern `endpoint-list` — single endpoint list with role enum and YANG choice** (when roles share similar structure or device count per role varies):

```yang
list <service-name> {
  key name;
  uses ncs:service-data;
  ncs:servicepoint "<service-name>-servicepoint";
  leaf name { type string; }
  leaf <common-param> { type <type>; mandatory true; tailf:info "..."; }
  list endpoint {
    key device;
    leaf device { type leafref { path "/ncs:devices/ncs:device/ncs:name"; } mandatory true; }
    leaf role {
      type enumeration { enum pe; enum ce; enum u-pe; enum access; }
      mandatory true;
      tailf:info "Device role in the service topology";
    }
    leaf interface-type {
      type enumeration { /* combined interface types from all roles — Step 2b */ }
      tailf:info "Interface type — required for roles with interface configuration";
    }
    choice role-config {
      case pe { leaf <pe-param> { type <type>; tailf:info "..."; } }
      case ce { leaf <ce-param> { type <type>; tailf:info "..."; } }
    }
  }
}
```

---

## Step 4 — Locate the Running NSO Instance

Determine `<ncs-run-dir>` for the active NSO:

1. Look for `ncs.conf` in the workspace root — if found, that directory is `<ncs-run-dir>`
2. Otherwise check `$NCS_RUN_DIR`, `~/nso-run-*` (auto-detected by `manage_package.sh`), or `/var/opt/ncs`
3. Verify NSO is running:
   ```bash
   ncs_status=$(ncs --status 2>/dev/null); echo "$ncs_status" | grep 'status: started'
   ```
4. If NSO is **not** running, halt and report — do not attempt to start it

---

## Step 5 — Create the Package Skeleton

Use `manage_package.sh` to scaffold, build, symlink, and optionally reload in one step. Run from the workspace root:

```bash
scripts/manage_package.sh <service-name> \
  --type python-and-template \
  --augment /ncs:services
```

This creates `packages/<service-name>/`, builds it, and symlinks it into the NSO runtime.

> Do **not** manually recreate files that `ncs-make-package` already generates (`Makefile`, `package-meta-data.xml`).

---

## Step 6 — Ensure a Matching NETSIM Device Exists

A device of the correct NED type must be present in NSO's inventory before generating the XML template.

**Check for an existing device:**
```bash
ncs_cli -Cu admin << 'EOF'
show devices list | include <ned-id-pattern>
EOF
```
If a suitable device exists, note its name as `<netsimDevice>` and skip creation.

**If no matching device exists**, find the NED package directory and create a netsim node:
```bash
# Identify the NED package dir (e.g. cisco-iosxr-cli-7.x)
ls <ncs-run-dir>/packages/ | grep <device-type>

# Create a single netsim node
ncs-netsim add-to-network <ncs-run-dir>/packages/<ned-package-dir> 1 <service-name>-sim
ncs-netsim start

# Load into NSO
ncs-netsim ncs-xml-init > /tmp/<service-name>-sim-init.xml
ncs_load -l -m /tmp/<service-name>-sim-init.xml

# Sync-from and verify
ncs_cli -Cu admin << 'EOF'
devices device <service-name>-sim sync-from
EOF
```
Confirm the result shows `result true` before continuing. Set `<netsimDevice>` to the new device name.

---

## Step 7 — Generate the XML Template via NSO

For **each** entry in the `(interface-type → file path)` list from Step 2b (or the single `<inputConfigFile>` if no interface variants), load the config through the real NED:

```bash
ncs_cli -Cu admin << 'EOF'
config
devices device <netsimDevice> load-native-config verbose file <per-interface-cfg-file>
show configuration | display xml
EOF
```

- Capture the XML payload (content between `<config>` tags, strip the device wrapper) for each interface type
- Store each captured payload labelled by its interface type

**Merge into a single template.** Lines identical across all variants are emitted once; lines that differ by interface type are wrapped in conditionals:

```xml
<config-template xmlns="http://tail-f.com/ns/config/1.0">
  <devices xmlns="http://tail-f.com/ns/ncs">
    <device>
      <name>{/device}</name>
      <config>
        <!-- shared config common to all interface types -->
        <?if {interface-type = 'GigabitEthernet'}?>
          <!-- GigabitEthernet XML payload with {/leaf-name} substitutions -->
        <?end?>
        <?if {interface-type = 'TenGigE'}?>
          <!-- TenGigE XML payload with {/leaf-name} substitutions -->
        <?end?>
        <?if {interface-type = 'Bundle-Ether'}?>
          <!-- Bundle-Ether XML payload with {/leaf-name} substitutions -->
        <?end?>
        <!-- repeat for every supported type — omitting one is a bug -->
      </config>
    </device>
  </devices>
</config-template>
```

- Replace each identified variable value with `{/leaf-name}` in every block
- Keep all static config verbatim

Write the merged template to:
```
packages/<service-name>/templates/<service-name>-template.xml
```

> **Always use the XML extracted from NSO as the authoritative template source — never hand-author device config XML.**

**Multi-role template merging** — in multi-config mode (`role-lists` or `endpoint-list` pattern), run `load-native-config` once per role config (and once per interface type within each role). Then merge all captured XML payloads into one template using **both** role conditionals **and** interface-type conditionals. Lines identical across all variants are emitted once outside any conditional:

```xml
<config-template xmlns="http://tail-f.com/ns/config/1.0">
  <devices xmlns="http://tail-f.com/ns/ncs">
    <device>
      <name>{/endpoint/device}</name>   <!-- or {/pe/device} for role-lists pattern -->
      <config>
        <!-- shared config common to all roles -->
        <?if {endpoint/role = 'pe'}?>
          <?if {endpoint/interface-type = 'GigabitEthernet'}?>
            <!-- PE GigabitEthernet XML payload with {/endpoint/<param>} substitutions -->
          <?end?>
          <?if {endpoint/interface-type = 'TenGigE'}?>
            <!-- PE TenGigE XML payload -->
          <?end?>
          <!-- repeat for every PE interface type -->
        <?end?>
        <?if {endpoint/role = 'ce'}?>
          <!-- CE XML payload (add interface-type conditionals if CE has variants) -->
        <?end?>
        <!-- repeat for every managed role -->
      </config>
    </device>
  </devices>
</config-template>
```

For the `role-lists` YANG pattern the template is applied once per role list iteration; adjust the XPath context accordingly (e.g., `{/pe/device}`, `{/ce/device}`).

---

## Step 8 — Write Python Service Callbacks

Read the YANG model to enumerate all service leaves, then write
`packages/<service-name>/python/<service-name>/main.py`:

```python
import ncs
from ncs.application import Service

class ServiceCallbacks(Service):
    @Service.create
    def cb_create(self, tctx, root, service, proplist):
        self.log.info(f'Service create: {service._path}')
        vars = ncs.template.Variables()
        vars.add('DEVICE',         service.device)
        vars.add('INTERFACE_TYPE', service.interface_type)  # supported: GigabitEthernet, TenGigE, Bundle-Ether
        vars.add('INTERFACE_ID',   service.interface_id)
        # add one vars.add() per {/leaf} token used in the template
        template = ncs.template.Template(service)
        template.apply('<service-name>-template', vars)

class Main(ncs.application.Application):
    def setup(self):
        self.log.info('Main RUNNING')
        self.register_service('<service-name>-servicepoint', ServiceCallbacks)

    def teardown(self):
        self.log.info('Main FINISHED')
```

**Rules:**
- Every `{/leaf-name}` token in the XML template must have a matching `vars.add('LEAF_NAME', service.leaf_name)` call
- Every YANG leaf referenced in the template must appear in `vars.add()`
- Do **not** add `vars.add()` for leaves not referenced in the template

**Multi-device endpoint iteration** — for the `endpoint-list` YANG pattern, `cb_create` must iterate `service.endpoint` and apply the template once per endpoint:

```python
for endpoint in service.endpoint:
    self.log.info(f'Configuring endpoint: {endpoint.device} role: {endpoint.role}')
    vars = ncs.template.Variables()
    vars.add('DEVICE', str(endpoint.device))
    vars.add('ROLE', str(endpoint.role))
    if hasattr(endpoint, 'interface_type') and endpoint.interface_type:
        vars.add('INTERFACE_TYPE', str(endpoint.interface_type))
    # Add role-specific variables — use hasattr to guard optional leaves
    if str(endpoint.role) == 'pe':
        vars.add('PE_PARAM', str(endpoint.pe_param))   # replace with actual leaf names
    elif str(endpoint.role) == 'ce':
        vars.add('CE_PARAM', str(endpoint.ce_param))   # replace with actual leaf names
    template = ncs.template.Template(service)
    template.apply('<service-name>-template', vars)
```

For the `role-lists` YANG pattern, iterate each role list separately and apply the template once per entry:

```python
for pe in service.pe:
    vars = ncs.template.Variables()
    vars.add('DEVICE', str(pe.device))
    vars.add('INTERFACE_TYPE', str(pe.interface_type))
    vars.add('PE_PARAM', str(pe.pe_param))   # replace with actual leaf names
    template = ncs.template.Template(service)
    template.apply('<service-name>-template', vars)
for ce in service.ce:
    vars = ncs.template.Variables()
    vars.add('DEVICE', str(ce.device))
    vars.add('CE_PARAM', str(ce.ce_param))   # replace with actual leaf names
    template = ncs.template.Template(service)
    template.apply('<service-name>-template', vars)
```

---

## Step 9 — Update the Package Skeleton Files

Replace the scaffolded placeholder files with the generated artifacts:
- `src/yang/<service-name>.yang` ← YANG model from Step 3
- `templates/<service-name>-template.xml` ← merged XML template from Step 7
- `python/<service-name>/main.py` ← Python callbacks from Step 8

Do not modify `package-meta-data.xml` or the `Makefile` unless a correction is required.

---

## Step 10 — Build and Verify the Package

Build and reload using `manage_package.sh`:

```bash
scripts/manage_package.sh packages/<service-name> \
  --build-only \
  --reload-packages
```

The script compiles the package, then runs `packages reload` and `show packages package <name>` in one step.

Confirm `oper-status up` in the output.

**If status is not `up`, iterate:**
```bash
# Read logs to diagnose the error
tail -50 ~/nso-run-*/logs/ncs-python-vm-<service-name>.log
tail -50 ~/nso-run-*/logs/ncserr.log

# Fix the affected file, then rebuild and reload
scripts/manage_package.sh packages/<service-name> \
  --build-only --reload-packages
```
Repeat until `oper-status up`. Only proceed to Step 11 once the package is confirmed up.

---

## Step 11 — End-to-End Service Test

With the package `up`, verify it produces correct device configuration.

### 1. Pick a test device

```bash
ncs_cli -Cu admin << 'EOF'
show devices device * ned-id
EOF
```
Use the first device whose NED matches `device-type` as `<testDevice>`.

**Multi-device mode** (`role-lists` or `endpoint-list` pattern): pick one test device per managed role from the device inventory. Record them as `<testDevice-pe>`, `<testDevice-ce>`, etc. If no suitable device exists for a given role, create a netsim device for that role's NED following the procedure in Step 6.

### 2. Derive test values

From `<inputConfigFile>`, extract one concrete value for every mandatory YANG leaf.

**Multi-device mode**: derive test values from each per-role config file. Build one service instance that includes endpoints for all managed roles (e.g., one PE endpoint + one CE endpoint).

### 3. Dry-run per interface type

For **each** supported interface type from Step 2b:

```bash
ncs_cli -Cu admin << 'EOF'
config
<service-name> test-instance device <testDevice>
interface-type GigabitEthernet
interface-id 0/0/0/1.100
<leaf1> <value1>
commit dry-run outformat native
EOF
```

The output **must** contain native CLI lines matching the expected device configuration.  
If the dry-run output is empty, incorrect, or errors: diagnose (template XPath, Python variable mapping, YANG type mismatch), fix the relevant file, run `--build-only --reload-packages`, and retry.

**Multi-device mode**: run a separate `commit dry-run` for each combination of role and interface type. For example, if PE supports GigE and TenGigE and CE has no interface variants, run: PE-GigE dry-run, PE-TenGigE dry-run, CE dry-run — all must produce non-empty, correctly structured native CLI output for their respective test devices.

Repeat for every supported interface type. All must produce correct non-empty output before proceeding.

### 4. Commit

```bash
ncs_cli -Cu admin << 'EOF'
config
<service-name> test-instance device <testDevice>
interface-type GigabitEthernet
interface-id 0/0/0/1.100
<leaf1> <value1>
commit
EOF
```

### 5. Verify device config was applied

```bash
ncs_cli -Cu admin << 'EOF'
show running-config devices device <testDevice> config
EOF
```
Confirm the expected configuration blocks are present.

### 6. Clean up the test instance

```bash
ncs_cli -Cu admin << 'EOF'
config
no <service-name> test-instance
commit
EOF
```

> If **any** step in this test loop fails, fix the package (YANG / template / Python), rebuild with `--build-only --reload-packages`, and re-run from sub-step 3. Do not report success until a full create → dry-run → commit → verify → delete cycle completes without errors for **every supported interface type**.

---

## Constraints

- **Never skip Step 0** — if a requirements doc exists, always process it before starting implementation
- **Never skip Step 2b** — missing it means rebuilding YANG, template, and Python from Step 3 onward
- Never invent device capabilities not present in the source config
- Never add service parameters that are not variable in the source config — use static values in the template instead
- Never manually create files that `ncs-make-package` already generates (`Makefile`, `package-meta-data.xml`)
- Never attempt to start NSO if it is not already running — halt and report instead
- If the device type is unrecognised, ask the user to confirm the NED package name before proceeding to Step 5
- Always use the XML extracted from NSO (`load-native-config`) as the authoritative template source
- In multi-device mode, do not report success until all roles and all interface type variants pass the full test cycle in Step 11

---

## Output Format

At the end, provide:
1. **Package layout tree** — all created/modified files
2. **Parameter table** — each YANG leaf → XML template variable → source config token
3. **Build and load status** — result of `make clean all` and `packages reload` with `oper-status`
4. **Test result** — `commit dry-run outformat native` output for each supported interface type, confirmation the final commit succeeded, and the relevant snippet from `show running-config` proving config was pushed to the device
