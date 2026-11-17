# Spec Document Template

Use this structure for the generated requirements spec.

```yaml
project_metadata:
  project_name: "REPLACE_ME"
  version: "1.0.0"
  description: "REPLACE_ME"

development_preferences:
  nso_version: "REPLACE_ME"
  ned_type: "REPLACE_ME"
  package_structure: "standard-blueprint"
  code_pattern: "REPLACE_ME"

network_context:
  topology_type: "REPLACE_ME"   # Options: Standalone, LSA

services:
  - service_name: "REPLACE_ME"

    service_variants:

      - subtype: "REPLACE_ME"

        description: >
          REPLACE_ME

        deployment_model:
          connectivity_type: "REPLACE_ME"
          routing_protocol: "REPLACE_ME"
          topology: "REPLACE_ME"

        supported_devices:
          - role: "REPLACE_ME"
            vendor: "REPLACE_ME"
            model: "REPLACE_ME"
            os_version: "REPLACE_ME"
            management_ip: "REPLACE_ME"

            ned:
              type: "REPLACE_ME"
              version: "REPLACE_ME"

            # Auto-generated from <VARIABLE_NAME> tokens found in this variant's config.
            # key  = lowercase_snake_case semantic name used by the automation
            # value = "<ORIGINAL_TOKEN>" exactly as it appears in raw_configuration
            # comment = short description inferred from surrounding config context
            instance_variables:
              variable_name: "<VARIABLE_NAME>"        # description inferred from config context
              another_variable: "<ANOTHER_VARIABLE>"  # description inferred from config context

            raw_configuration: |
              REPLACE_ME
```

## Formatting Rules

- Repeat `service_variants` entries for every discovered variant.
- Repeat `supported_devices` entries when a variant applies to multiple device types.
- Place `instance_variables:` immediately before `raw_configuration:` inside each `supported_devices` entry.
- Omit `instance_variables:` entirely for a variant that has no `<...>` tokens in its config.
- Preserve `<VARIABLE_NAME>` tokens exactly as-is inside `raw_configuration` blocks.
- Use `REPLACE_ME` only after asking the user and receiving permission to leave placeholders.
- Keep comments limited to allowed option hints and variable descriptions, not inferred explanations.

## instance_variables Rules

### Format
```yaml
instance_variables:
  lowercase_key: "<ORIGINAL_TOKEN>"   # Short description
```

- **Key**: lowercase snake_case version of the token name (e.g. `<VRF_NAME>` → `vrf_name`).
- **Value**: the original `<ORIGINAL_TOKEN>` string, quoted, exactly as it appears in the raw config.
- **Inline comment**: a short human-readable description inferred from the config keyword or line context immediately surrounding the token.

### Description inference examples
| Config line containing token | Inferred description |
|---|---|
| `vrf <VRF_NAME>` | VRF name for the service instance |
| `ipv4 address <PE_CE_IP>` | PE-CE interface IPv4 address |
| `encapsulation dot1q <VLAN_ID>` | VLAN ID for sub-interface encapsulation |
| `rd <RD>` | Route distinguisher for the VRF |
| `remote-as <REMOTE_AS>` | BGP remote AS number of the CE |
| `route-target import <ROUTE_TARGET>` | BGP route-target for VRF import |
| `route-target export <ROUTE_TARGET>` | BGP route-target for VRF export |
| `description <INTF_DESCRIPTION>` | Interface description string |
| `password encrypted <BGP_PASSWORD_ENCRYPTED>` | Encrypted BGP neighbor password |

### Shared variables
If the same `<TOKEN>` appears in more than one variant, emit it in each variant's `instance_variables:` block and append `# shared across variants` to the inline comment:
```yaml
instance_variables:
  vrf_name: "<VRF_NAME>"   # VRF name for the service instance — shared across variants
```

### Deduplication within a variant
Each token appears only once in a variant's `instance_variables:` block, even if it appears multiple times in that variant's `raw_configuration`.
