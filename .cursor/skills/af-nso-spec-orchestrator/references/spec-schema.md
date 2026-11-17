# Spec Schema — fields consumed by af-nso-spec-orchestrator

The orchestrator ingests a service spec YAML. This documents the fields it reads.

## Top-level structure

```yaml
project_metadata:
  project_name: "..."
  version: "1.0.0"
  description: "..."

development_preferences:
  nso_version: "6.2"                 # REQUIRED — target NSO version
  ned_type: "cisco-iosxr,cisco-nx"   # comma-separated NED slugs
  package_structure: "standard-blueprint"
  code_pattern: "python"             # python (supported) | java (halts in v1)

network_context:
  topology_type: "Standalone"        # Standalone (supported) | LSA (halts in v1)

devices:
  - role: "Core-Router"
    vendor: "cisco"
    model: "asr9k"
    os_version: "7.7.1"
    management_ip: "10.1.1.1"        # informational; netsim assigns addressing

services:
  - service_name: "L3VPN"
    service_variants:
      - subtype: "L3VPN Full Mesh Connected"
        deployment_model:
          connectivity_type: "dynamic"
          routing_protocol: "BGP"
          topology: "full-mesh"
        supported_devices:
          - role: "Core-Router"
            ned:
              type: "cisco-iosxr"    # REQUIRED per device
              version: "7.45"        # REQUIRED per device
            instance_variables:      # OPTIONAL — elicited before build (Step 3)
              vrf_name: "<vrf-name>"          # description  # shared across variants
              interface_ip: "<interface-ip>"  # PE-CE interface IPv4 address
              password: "<password>"          # Encrypted BGP neighbor password
            raw_configuration: |     # REQUIRED — native CLI for this variant
              vrf <vrf-name>
              ...
```

## Instance variables (`instance_variables`)

Each variant's `raw_configuration` uses **angle-bracket placeholders** (e.g.
`<vrf-name>`). The optional `instance_variables` map declares those placeholders:

- **Key** — the variable name (e.g. `vrf_name`); underscores in the key, hyphens
  in the token.
- **Value** — the placeholder token exactly as it appears in `raw_configuration`
  (e.g. `"<vrf-name>"`).
- **Trailing comment** — a human description; a comment containing
  `shared across variants` marks the variable as **shared**.

The orchestrator collects concrete values for these in **Step 3 (elicitation)**
before any package is built, because `raw_configuration` with placeholders is not
valid device config for `load-native-config`.

| Comment marker | Collection behavior |
|---|---|
| `shared across variants` | Collect **one** value; reuse across every variant that uses it |
| (none) | Collect a value **per variant** that declares it |

Rules:
- Preserve key names **verbatim**, including source typos (e.g.
  `intergace_type_and_id` → token `<intergace-type-and-id>`). Map by the literal
  token found in `raw_configuration`.
- Every `<...>` token used in a variant's `raw_configuration` MUST receive a
  non-empty value, or the orchestrator halts before building that variant.
- **Credential variables** (e.g. `password`) are secrets: taken at prompt time
  only, never persisted to the spec/package/any file, never echoed back.
- A variant may declare more variables than another (e.g. the full-mesh variant
  adds `neighbor_ip`, `remote_as`, `password`, `as_override`); collect each
  variant's own token set.

## Field consumption

| Field | Used for | Required |
|---|---|---|
| `development_preferences.nso_version` | Step 4a NSO version reconciliation | Yes |
| `development_preferences.ned_type` | Seeds the required-NED set (comma list) | No* |
| `development_preferences.code_pattern` | Step 2 guardrail (`java` → halt) | No (defaults python) |
| `network_context.topology_type` | Step 2 guardrail (`LSA` → halt) | No (defaults Standalone) |
| `devices[]` | Step 4c netsim device reconciliation | Yes (≥1) |
| `service_variants[].subtype` | Package naming + report labeling | Yes |
| `service_variants[].deployment_model` | Passed to service-from-config context | No |
| `supported_devices[].ned.type` + `.version` | Step 4b required-NED set | Yes |
| `supported_devices[].instance_variables` | Step 3 variable elicitation | No |
| `supported_devices[].raw_configuration` | Step 5 package build source | Yes |

\* `ned_type` is a convenience list; the authoritative required-NED set is the
union of `ned_type` and every per-device `ned` block.

## Required-NED set construction

Collect every distinct `(type, version)` pair from:
1. Each per-device `supported_devices[].ned` block (authoritative — has version).
2. `development_preferences.ned_type` slugs (version resolved from matching
   per-device blocks; if a slug has no version anywhere, halt and report).

## Missing-field handling

If any **Required** field above is absent, the orchestrator halts in Step 1 and
reports the exact field path (e.g.
`services[0].service_variants[2].supported_devices[0].raw_configuration`) without
starting reconciliation.

## Notes on the sample specs

- A spec with `topology_type: LSA` and `code_pattern: java` exercises **both** v1 halt guardrails.
- A spec with `Standalone` + `python` is a supported configuration; its `raw_configuration` blocks
  contain angle-bracket placeholders that service-from-config parameterizes into the YANG model.
- A spec with `Standalone` + `python` and `instance_variables` per variant exercises the Step 3
  elicitation flow, including a `shared across variants` set, a per-variant `password` secret,
  and a preserved source typo (e.g. `intergace_type_and_id`).
