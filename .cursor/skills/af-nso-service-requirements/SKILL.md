---
name: af-nso-service-requirements
description: "Elicit a new NSO service design from scratch through structured Q&A when the user has no source config or document. Use for: design service, plan service package, describe service, service topology, gather service requirements, new service from scratch, multi-device VPN service, VPN service design. Front-end to af-nso-spec-document (Stage 1): produces a requirements document and per-device-role native CLI config templates that spec-document turns into aifirstspec/inputs/<name>.yaml."
argument-hint: "service-name='<name>' service-type='<L2VPN|L3VPN|custom>'"
license: Proprietary
---

# NSO Service Requirements Gathering

The **Stage-1 elicitation front-end** of the canonical package-development
pipeline. Use it when the user asks for a service but supplies **no source
material** (no config, no requirements document) — it gathers the design through
structured conversation and produces the raw material that
**af-nso-spec-document** turns into `aifirstspec/inputs/<name>.yaml`. It does not
build anything itself; it only produces a requirements document and per-device-role
native CLI config templates for spec-document to author from.

## Inputs

Collect before starting (ask for missing values):
- **service-name** *(optional)*: Name for the service package; will be confirmed in Step 1 if not provided
- **service-type** *(optional)*: High-level service type; will be confirmed in Step 1 if not provided

---

## Workflow

### Step 1 — Service Identity

Ask the user for all of the following in a single prompt:

1. **Service name** — will become the NSO package name (e.g., `l2vpn-eline`, `l3vpn-vrf`, `mpls-te-tunnel`)
2. **Service type** — choose from: L2VPN E-Line, L2VPN E-LAN, L3VPN, MPLS TE, or Custom (describe)
3. **Service description** — one or two sentences explaining what this service accomplishes
4. **Target NED / device platform** — e.g., `cisco-iosxr-cli-7.76`, `cisco-ios-xe-cli-3.18`, `juniper-junos-nc-4.1`

Wait for all four answers before continuing.

---

### Step 2 — Service Scope

Ask: **"How many PE devices does a single service instance span — one, or multiple?"**

- Record the answer as `<pe-count>` (1 or many)
- This is the primary driver of the YANG structure decision in Step 7

Wait for an explicit answer. Do not infer or default.

---

### Step 3 — Device Role Inventory

Present the following role taxonomy and ask which roles are involved and how many devices of each role exist per service instance:

| Role   | Description |
|--------|-------------|
| PE     | Provider Edge — direct connection to the MPLS/IP core |
| U-PE   | User-facing PE — aggregation layer between Access and PE |
| CE     | Customer Edge — customer-premises device connecting to PE |
| Access | Access layer device connecting to CE or U-PE |
| Other  | Describe the role |

Ask: **"Which of these device roles are part of this service? For each role, how many devices per service instance?"**

Example expected answer: *"PE: 2, CE: 1 per PE"* or *"PE: 1, U-PE: 1, Access: 1"*

Wait for an explicit answer listing roles and counts.

---

### Step 4 — Management Status per Role

For **each** role identified in Step 3, ask individually:

> "Is the **[role]** device managed by NSO — i.e., will NSO push configuration to it via a NED?"

- **Yes (NSO-managed)**: this role is in scope for YANG modeling and template generation
- **No (unmanaged / out-of-band)**: document the role in the requirements for reference but exclude it from all YANG and template artifacts

Build and record a management status table:

| Role | Count/instance | NSO-managed? |
|------|---------------|--------------|
| PE   | ...           | Yes/No       |
| CE   | ...           | Yes/No       |

---

### Step 5 — Configuration Requirements per Managed Role

For **each NSO-managed role**, ask in turn:

> "Do you have a sample native CLI config snippet for a **[role]** device? If yes, paste it. If no, describe what configuration needs to be applied."

**If native CLI is provided:**
- Identify all variable parameters (IP addresses, interface IDs, VPN/VRF identifiers, route-targets, AS numbers, policy names, etc.)
- Note each parameter and the config block it appears in
- Flag any ambiguous parameters and confirm with the user

**If no native CLI — ask guided questions for that role:**
- Interface configuration? (type: GigabitEthernet / TenGigE / Bundle-Ether / other; ID pattern; encapsulation: dot1q, qinq, or none)
- VRF or VPN identifiers? (VRF name, route distinguisher, route-target import/export)
- BGP configuration? (AS number, neighbor, address-family, redistribute)
- OSPF or static routing?
- MPLS / xconnect / EVPN? (EVI, xconnect group, p2p name, neighbor AC IDs)
- Sub-interface or main interface?
- QoS policies?
- Any other feature-specific configuration?

Compile the answers into a parameter list for the role before moving on to the next.

---

### Step 6 — Parameter Classification

After completing Step 5 for all managed roles, compile a full parameter inventory across all roles. For each parameter, propose a classification and present a draft table for the user to confirm or correct:

| Parameter | Type | Proposed Classification | Role(s) |
|-----------|------|------------------------|---------|

Classification rules to apply when proposing:
- **Service-level (common)**: same single value shared by all devices in the instance (e.g., xconnect group name, VPN ID, BGP AS number, EVI, VRF name)
- **Per-device (per-endpoint)**: a distinct value per device instance (e.g., interface name, IP address, sub-interface ID, device leafref)
- **Per-role**: specific to one device role; same within that role but different from other roles (e.g., CE-facing policy name, PE VRF route-target export community)

Ask: **"Does this classification look correct? Please confirm or adjust any entries."**

Wait for explicit confirmation before proceeding.

---

### Step 7 — YANG Design Recommendation

Based on `<pe-count>` from Step 2 and the roles/counts from Step 4, apply the following decision tree. Present the recommendation with its tradeoffs and ask the user to confirm before locking it in.

---

**Case 1: 1 PE, no other NSO-managed devices**

→ **Flat YANG** (same pattern as existing `l2vpn-eline` and `l3vpn-static-rt` packages)

```
module: <service-name>
 +-rw <service-name> [name]
    +-rw name              string
    +-rw device            leafref      // → PE device
    +-rw <common-param>    <type>
    +-rw <device-param>    <type>
```

- Tradeoff: simple to implement and read; limited to one PE per service instance

---

**Case 2: 1 PE + one or more managed CE / U-PE / Access devices**

→ **Default: one NSO package**. Present two structural options:

**Option A — Separate role lists** (recommended when PE and CE configs differ significantly in structure):

```
module: <service-name>
 +-rw <service-name> [name]
    +-rw name              string
    +-rw <common-param>    <type>         // service-level
    +-rw pe [device]
    |  +-rw device         leafref
    |  +-rw <pe-param>     <type>
    +-rw ce [device]
       +-rw device         leafref
       +-rw <ce-param>     <type>
```

- Tradeoff: each role's leaves are clearly separated; good when role configs are structurally very different; list keys are independent

**Option B — Endpoint list with role choice** (recommended when PE and CE share a similar parameter structure or device count per role may vary):

```
module: <service-name>
 +-rw <service-name> [name]
    +-rw name              string
    +-rw <common-param>    <type>         // service-level
    +-rw endpoint [device]
       +-rw device         leafref
       +-rw role           enumeration { pe | ce | u-pe | access }
       +-rw (role-config)
          +--:(pe)
          |  +-rw <pe-param>  <type>
          +--:(ce)
             +-rw <ce-param>  <type>
```

- Tradeoff: more flexible and uniform key structure; role-specific leaves cleanly separated with YANG choice; slightly more complex XPath in templates

> **Two separate packages** (one per role) enables fully independent provisioning and lifecycle management per device role. Only surface this option if the user explicitly raises the need — the default is always one package.

---

**Case 3: Multiple PEs per instance**

→ **Default: one NSO package** with a `list pe [device]`.

- If each CE is tightly bound to one specific PE: use a nested `list ce` inside `list pe`
- If CE count varies independently of PE count: use a flat `list endpoint [device]` with a `role` leaf

Show both structural variants and ask the user to confirm based on the binding relationship.

---

Ask: **"Which YANG option do you prefer? Please confirm the recommendation or choose an alternative."**

Record the confirmed pattern as `<yang-pattern>`: `flat`, `role-lists`, or `endpoint-list`. This value flows through the spec into the downstream build (af-nso-spec-orchestrator → af-nso-manage-package service-from-config step).

---

### Step 8 — Save Requirements Document

Locate `<ncs-run-dir>`:
1. Look for `ncs.conf` in the current workspace root — if found, that directory is `<ncs-run-dir>`
2. Otherwise check `$NCS_RUN_DIR` or `~/nso-run-*` (auto-detected)

Write the requirements document to `<ncs-run-dir>/input-configs/<service-name>-requirements.md` with all of the following sections:

**1. Service Overview**

| Field         | Value |
|---------------|-------|
| Service name  | ...   |
| Service type  | ...   |
| Description   | ...   |
| Target NED    | ...   |
| YANG pattern  | ...   |

**2. Topology Diagram** (ASCII art showing device roles and connections)

```
[Access] → [U-PE] → [PE] ↔ Core ↔ [PE] → [CE]
```

**3. Device Roles Table**

| Role | Count/instance | NSO-managed | Notes |
|------|---------------|-------------|-------|

**4. Parameter Classification Table**

| Parameter | YANG type | Classification | Role(s) | Notes |
|-----------|-----------|---------------|---------|-------|

**5. YANG Design**
- Confirmed pattern: `<yang-pattern>`
- Rationale (one paragraph explaining why this pattern was chosen)
- YANG tree-notation skeleton showing all leaves

**6. Handoff Instructions**
- List the per-role config files created in Step 9 (absolute paths)
- Note that **af-nso-spec-document** consumes this requirements document and the
  per-role config files as its source input, producing
  `aifirstspec/inputs/<service-name>.yaml`
- Any `<PLACEHOLDER>` tokens in the config are intentional per-instance
  parameters: spec-document preserves them as `<VARIABLE_NAME>` tokens and
  records them under each variant's `instance_variables`; concrete values are
  collected later at build time (orchestrator), not here

---

### Step 9 — Generate Per-Role Config Templates

For each NSO-managed device role:

**If native CLI was provided in Step 5:**
- Save it as-is to `<ncs-run-dir>/input-configs/<service-name>-<role>.cfg`
- Annotate each variable parameter with an inline comment: `! PARAM: <param-name>`

**If no native CLI was provided:**
- Construct a representative config template using `<PLACEHOLDER_NAME>` tokens for all variable parameters identified in Steps 5–6
- Use the same config structure, keywords, and command hierarchy described by the user
- Add a header comment block:
  ```
  ! TEMPLATE - Replace all <PLACEHOLDER> tokens with real device values before use
  ! Generated by af-nso-service-requirements skill for role: <role>
  ! Service: <service-name>
  ```
- Save to `<ncs-run-dir>/input-configs/<service-name>-<role>.cfg`

> **Note**: `<PLACEHOLDER>` tokens are intentional per-instance parameters, not
> missing values. **af-nso-spec-document** preserves them as `<VARIABLE_NAME>`
> tokens and records them under each variant's `instance_variables`; the
> orchestrator collects concrete values at build time before `load-native-config`
> runs. Do not ask the user to fill them in here.

Print all created file paths.

---

### Step 10 — Handoff

Tell the user:

> "Requirements gathering complete. Created:
> - `input-configs/<service-name>-requirements.md` — full design reference
> - `input-configs/<service-name>-<role>.cfg` — [one line per managed role]
>
> YANG pattern confirmed: **[flat / role-lists / endpoint-list]**"

Then ask: **"Are you ready to author the spec from these requirements? I can invoke af-nso-spec-document now."**

Wait for an explicit answer. Do not infer or proceed without confirmation.

- **If yes**: invoke **af-nso-spec-document** (Stage 1 of the pipeline), passing the
  requirements doc and all per-role config file paths as the source input.
  spec-document produces `aifirstspec/inputs/<service-name>.yaml`; the
  orchestrator then registers, plans, and builds it.

- **If no**: end the skill and tell the user the requirements doc + per-role
  configs are ready; they can invoke **af-nso-spec-document** against them at any
  time to author the spec.

This offer applies regardless of the number of device roles (single or multi-role).

---

## Constraints

- DO NOT generate a compilable YANG `.yang` file — that is the responsibility of `af-nso-manage-package`
- DO NOT generate XML device templates — those are produced by `af-nso-manage-package` via NSO's real NED
- Wait for explicit user confirmation at Steps 2, 3, 4, 6, 7, and 10 — do not infer or skip ahead
- Always default to one NSO package; only surface multi-package options if the user explicitly raises independent lifecycle requirements per device role
- If a constructed config template contains `<PLACEHOLDER>` tokens, issue the warning stated in Step 9 before handing off

## Output

At the end of the skill, provide:
1. A list of all files created with absolute paths
2. A summary table of the confirmed YANG pattern and all classified parameters
3. The handoff prompt (Step 10)
