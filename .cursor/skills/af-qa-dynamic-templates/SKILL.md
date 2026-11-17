---
name: af-qa-dynamic-templates
description: 'Repair an existing CXTA Jinja template after validate_cxta_gate3_assets.sh names an undefined variable. Do not load this skill while generating Robot scripts.'
argument-hint: "template task or path (e.g. 'convert a static HSSTA test to dynamic templates', 'validate templates in qa/03_cxta_automation/', 'add /30 pool for hssta'); 'list' to enumerate current .j2 templates"
alwaysApply: false
license: Proprietary
---

# Skill: QA Dynamic Template Management

Gate 3 script generation does not open this file. Open it only after
`scripts/validate_cxta_gate3_assets.sh` names an undefined template variable.

**ID:** `af-qa-dynamic-templates`  
**Version:** 1.1.0

**Category:** Testing & QA

## Purpose

Manage dynamic test templates for CXTA NSO automation tests. This skill enables test cases to use Jinja2 templates with variable substitution for device names, IP addresses, AS numbers, VRF names, and other test-specific values, allowing IP address allocation from testbed YAML pools and reducing test maintenance burden.

## When to Use This Skill

- **Converting static test assets** to dynamic templates
- **Creating new test cases** that need dynamic IP allocation
- **Validating template syntax** before test execution
- **Troubleshooting template rendering** issues
- **Managing testbed IP pools** and allocation strategy

## Prerequisites

1. **Repository structure**: `qa/03_cxta_automation/` with standard CXTA layout
2. **Python environment**: Repository virtualenv with Jinja2 installed
   ```bash
   source .venv/bin/activate  # Repository shared virtualenv
   pip list | grep -i jinja2  # Should show jinja2>=3.0
   ```
3. **Enhanced NsoLib**: `qa/03_cxta_automation/libraries/nso/NsoLib.py` with dynamic functions
4. **Testbed YAML**: `qa/03_cxta_automation/environments/testbed_<spec-id>.yaml` with IP pools

## Core Concepts

### Template Files

Dynamic tests use Jinja2 templates (`.j2` extension) instead of static files:

Templates live in the Jenkins-discoverable layout
`qa/03_cxta_automation/tests/<SERVICE>/<PLATFORM>/<FUNCTION>/<FLAVOR>/`,
one file per TC ID:

| File Type | Static | Dynamic Template | Location | Purpose |
|-----------|--------|------------------|----------|---------|
| Service Config | `.cfg` | `.cfg.j2` | `config/<TC-ID>.cfg.j2` | RESTCONF PUT payload for service creation |
| Modify Payload | `.patch` | `.patch.j2` | `config/<TC-ID>.patch.j2` | RESTCONF PATCH payload for the modify step |
| Golden Device Config | `.expected.json` | `.expected.j2` | `expected/<TC-ID>.expected.j2` | JSON-shaped golden config compared with the device |
| Preconfig | `.pre.cfg` | `.pre.cfg` (static JSON) | `preconfig/<TC-ID>.pre.cfg` | Top-level `device` and `config`; mounted-NED config is encoded as XML by `preconfig_xml.py` |
| Per-TC Testdata | `.yaml` | `.yaml` (static) | `qa/03_cxta_automation/tests/<SERVICE>/<PLATFORM>/testdata/<TC-ID>.yaml` | `inputs` passed to `Build Test Context` |

### Template Variables

Variables built by `NsoLib.build_test_context()`. The library computes only
`device`, `device_name`, `sequence`, `interface_ip`, `neighbor_ip`,
`prefix_length`, `subnet`, `int_ipv4_prefix`, `physical_port`,
`prefix_set_ipv4`, and `remote_as`. Every other template variable must exist
in `test_data.defaults` or the TC's `inputs`; never assume the library
synthesizes it. Inputs override defaults.

| Variable | Example Value | Description |
|----------|--------------|-------------|
| `{{ test_name }}` | `QA-L3VPN-HSSTA-001` | Service instance name |
| `{{ vrf_name }}` | `QA-HSSTA-001` | Unique VRF name for the test instance |
| `{{ vrf_description }}` | `QA Hub Static site 001` | VRF description |
| `{{ device }}` | `PE1` | Testbed device alias |
| `{{ device_name }}` | `pe0` | NSO device name (`devices.<alias>.name` in the testbed) |
| `{{ interface_ip }}` | `192.168.120.1` | PE interface IP (first host address of the pool /30) |
| `{{ neighbor_ip }}` | `192.168.120.2` | CE/neighbor IP (second host address of the /30) |
| `{{ prefix_length }}` | `30` | Prefix length of the pool subnet |
| `{{ subnet }}` | `255.255.255.252` | Subnet mask (`test_data.defaults.subnet_mask`) |
| `{{ as_number }}` | `65102` | Must be supplied by defaults or TC inputs |
| `{{ remote_as }}` | `65002` | `test_data.as_numbers.remote_base + sequence` |
| `{{ rt_value }}` | `301` | Route-target value; the route target is `{{ as_number }}:{{ rt_value }}` |
| `{{ rd_value }}` | `65102:3001` | Route distinguisher |
| `{{ dot1q }}` | `57` | VLAN ID (flavor default: FMESH 100, HSCON 13, HSSTA 57) |
| `{{ interface_type_and_id }}` | `GigabitEthernet0/0/0/3.57` | Sub-interface identifier |
| `{{ interface_description }}` | `PE-CE hssta site-001` | Interface description |
| `{{ mtu }}` | `1500` | Interface MTU (`test_data.defaults.mtu`) |
| `{{ static_prefix }}` / `{{ static_nexthop }}` | `10.50.0.0/24` / `192.168.120.2` | Static-route values (HSSTA) |
| `{{ password }}` | (secret) | Full-mesh BGP password, read from the `BGP_NEIGHBOR_PASSWORD` environment variable; never log or hardcode it |

### Testbed IP Pool Structure

Testbed YAML (`environments/testbed_<spec-id>.yaml`, e.g. `testbed_l3vpn.yaml`) contains one IP pool per FLAVOR (`fmesh`, `hscon`, `hssta`). The pool entry at index `sequence - 1` is used for a test, so `sequence: 1` takes the first /30:

```yaml
testbed:
  # nso: connection block omitted
  devices:
    PE1:
      name: pe0
      ned_id: cisco-iosxr-cli-7.75
  ip_pools:
    fmesh:
      - "192.168.100.0/30"
      - "192.168.100.4/30"
      - "192.168.100.8/30"
      # ... more /30 subnets
    hscon:
      - "192.168.110.0/30"
      - "192.168.110.4/30"
      # ...
    hssta:
      - "192.168.120.0/30"
      - "192.168.120.4/30"
      # ...
  test_data:
    as_numbers:
      base: 65000
      increment: 1
    defaults:
      mtu: 1500
      subnet_mask: 255.255.255.252
```

## Procedures

### Procedure 1: Convert Static Test to Dynamic Template

**Use Case:** Convert an existing test with hardcoded values to dynamic templates. The worked example is `TC.L3VPN.NSO.SVC.HSSTA.CRTE.MOD.DRYRUN.DEL.RLBK.0001` under `qa/03_cxta_automation/tests/L3VPN/NSO/SVC/HSSTA/`.

**Steps:**

1. **Identify the test case** and canonical FLAVOR directory from the Planner's catalog (`qa/02_testcases/<spec-id>_TestCases_LLD.csv`).

2. **Backup original files:**
   ```bash
   cd qa/03_cxta_automation/tests/L3VPN/NSO/SVC/HSSTA
   TC=TC.L3VPN.NSO.SVC.HSSTA.CRTE.MOD.DRYRUN.DEL.RLBK.0001
   cp config/$TC.cfg config/$TC.cfg.bak
   cp expected/$TC.expected.json expected/$TC.expected.json.bak
   ```

3. **Convert service config to template:**
   - Rename `.cfg` → `.cfg.j2`
   - Replace hardcoded values with template variables
   
   **Original (`config/TC.L3VPN.NSO.SVC.HSSTA.CRTE.MOD.DRYRUN.DEL.RLBK.0001.cfg`):**
   ```json
   {
     "l3vpn:l3vpn": {
       "name": "QA-L3VPN-HSSTA-001",
       "variant": "hub-spoke-static",
       "device": "pe0",
       "vrf-name": "QA-HSSTA-001",
       "vrf-description": "QA Hub Static site 001",
       "as-number": 65102,
       "rt-value": 301,
       "rd-value": "65102:3001",
       "interface-type-and-id": "GigabitEthernet0/0/0/3.57",
       "interface-description": "PE-CE hssta site-001",
       "interface-ip": "192.168.120.1",
       "prefix-length": 30,
       "mtu": 1500,
       "static-prefix": "10.50.0.0/24",
       "static-nexthop": "192.168.120.2"
     }
   }
   ```
   
   **Template (`config/TC.L3VPN.NSO.SVC.HSSTA.CRTE.MOD.DRYRUN.DEL.RLBK.0001.cfg.j2`):**
   ```jinja2
   {# Jinja2 template: Hub and Spoke Static create payload #}
   {
     "l3vpn:l3vpn": {
       "name": "{{ test_name }}",
       "variant": "hub-spoke-static",
       "device": "{{ device_name }}",
       "vrf-name": "{{ vrf_name }}",
       "vrf-description": "{{ vrf_description }}",
       "as-number": {{ as_number }},
       "rt-value": {{ rt_value }},
       "rd-value": "{{ rd_value }}",
       "interface-type-and-id": "{{ interface_type_and_id }}",
       "interface-description": "{{ interface_description }}",
       "interface-ip": "{{ interface_ip }}",
       "prefix-length": {{ prefix_length }},
       "mtu": {{ mtu }},
       "static-prefix": "{{ static_prefix }}",
       "static-nexthop": "{{ static_nexthop }}"
     }
   }
   ```

   Numeric leaves (`as-number`, `rt-value`, `prefix-length`, `mtu`) stay unquoted and string leaves stay quoted, so the rendered output is valid JSON. Model constants such as `"variant": "hub-spoke-static"` stay literal; only per-instance values become variables.

4. **Convert golden device config to template:**
   - Rename `.expected.json` → `.expected.j2`
   - Replace hardcoded values with the same template variables
   
   **Template (`expected/TC.L3VPN.NSO.SVC.HSSTA.CRTE.MOD.DRYRUN.DEL.RLBK.0001.expected.j2`):**
   ```jinja2
   {# Golden VRF subtree for the Hub and Spoke Static create #}
   {
     "device_config_subtree": "netsim-ned-cisco-ios-xr:vrf",
     "device_config": {
       "vrf": {
         "vrf-list": [{
           "name": "{{ vrf_name }}",
           "description": "{{ vrf_description }}",
           "address-family": {
             "ipv4": {
               "unicast": {
                 "import": {
                   "route-target": {
                     "address-list": [{"name": "{{ as_number }}:{{ rt_value }}"}]
                   }
                 },
                 "export": {
                   "route-target": {
                     "address-list": [{"name": "{{ as_number }}:{{ rt_value }}"}]
                   }
                 }
               }
             }
           }
         }]
       }
     }
   }
   ```

   `device_config_subtree` names the device subtree that `Verify Golden Device Config For TC` reads through NSO, and `device_config` holds the expected content; only the keys listed there are compared. The QA Builder keeps one YANG subtree per golden file.

5. **Create per-TC testdata** (`qa/03_cxta_automation/tests/L3VPN/NSO/testdata/<TC-ID>.yaml`) holding the instance values that were hardcoded:
   
   ```yaml
   tc_id: TC.L3VPN.NSO.SVC.HSSTA.CRTE.MOD.DRYRUN.DEL.RLBK.0001
   inputs:
     variant: hssta
     device: PE1
     sequence: 1
     test_name: QA-L3VPN-HSSTA-001
     vrf_name: QA-HSSTA-001
     vrf_description: QA Hub Static site 001
     as_number: "65102"
     rt_value: "301"
     rd_value: "65102:3001"
     interface_type_and_id: GigabitEthernet0/0/0/3.57
     interface_description: PE-CE hssta site-001
   ```

   `variant` selects the IP pool and `sequence` the /30 inside it; every other key overrides the default built by `NsoLib.build_test_context()`.
   
6. **Update the Robot script** (`scripts/<TC-ID>.robot`) to render the templates through the L3VPN keywords:

   ```robot
   *** Settings ***
   Documentation    Hub and Spoke Static: create, verify golden config, delete
   Library          ../../../../../../libraries/nso/NsoLib.py
   Resource         ../../../../../../keywords/nso/l3vpn_keywords.robot
   Suite Setup      Suite Setup L3VPN
   Test Tags        P0    HSSTA    positive    CRTE

   *** Variables ***
   ${TC_ID}         TC.L3VPN.NSO.SVC.HSSTA.CRTE.MOD.DRYRUN.DEL.RLBK.0001
   ${FLAVOR_DIR}    ${CURDIR}/..

   *** Test Cases ***
   Hub and Spoke Static create and delete
       [Teardown]    Remove Service Instance
       Log Step    1    Deploy ${TC_ID} from template
       Deploy L3VPN Service From Template    ${TC_ID}    ${FLAVOR_DIR}
       Wait For L3VPN Plan Ready    ${TC_ID}
       Assert L3VPN Service Deployed    ${TC_ID}
       Log Step    2    Verify golden device config on PE1
       Verify Golden Device Config For TC    ${TC_ID}    ${FLAVOR_DIR}    PE1
       Log Step    3    Delete the service and verify cleanup
       Delete L3VPN Service For TC    ${TC_ID}
       Verify Service Removed After Delete    ${TC_ID}

   *** Keywords ***
   Remove Service Instance
       ${context}=    Get Test Context
       IF    'test_name' in $context
           Delete Service If Exists    ${context}[test_name]
       END
   ```

   `Deploy L3VPN Service From Template` loads `testdata/<TC-ID>.yaml`, builds the context, renders `config/<TC-ID>.cfg.j2` and PUTs it; `Verify Golden Device Config For TC` renders `expected/<TC-ID>.expected.j2`. A TC with a modify step adds `config/<TC-ID>.patch.j2` (for example `{"l3vpn:l3vpn": {"vrf-description": "QA modified site 001"}}`) and calls `Modify L3VPN Service From Template`. The QA Builder still adds the remaining TC steps (dry-run and modify checks) required by its mandatory-validation rule; this script shows the templating pattern.

7. **Validate template syntax** (see Procedure 3)

8. **Test rendering** with the TC's testdata:
   ```python
   # Run from qa/03_cxta_automation/ (the folder that contains libraries/)
   from libraries.nso.NsoLib import NsoLib
   import json
   import yaml

   tc_id = 'TC.L3VPN.NSO.SVC.HSSTA.CRTE.MOD.DRYRUN.DEL.RLBK.0001'
   base = 'tests/L3VPN/NSO'

   nso = NsoLib()
   nso.load_testbed('environments/testbed_l3vpn.yaml')

   with open(f'{base}/testdata/{tc_id}.yaml') as f:
       test_params = yaml.safe_load(f)['inputs']

   context = nso.build_test_context(test_params)
   print("Test Context:", {k: v for k, v in context.items() if k != 'password'})

   rendered_cfg = nso.render_payload_template(f'{base}/SVC/HSSTA/config/{tc_id}.cfg.j2', context)
   print("Rendered Config:", json.dumps(json.loads(rendered_cfg), indent=2))
   ```

### Procedure 2: Create New Dynamic Test Case

**Use Case:** Create a new test case using dynamic templates from scratch. The worked example is a negative test, `TC.L3VPN.NSO.SVC.FMESH.CRTE.MOD.DRYRUN.DEL.RLBK.0013` (Full Mesh: reject omission of `vrf_name`).

**Steps:**

1. **Determine test parameters:**
   - TC ID from the Planner's catalog (e.g., `TC.L3VPN.NSO.SVC.FMESH.CRTE.MOD.DRYRUN.DEL.RLBK.0013`, a P0 negative TC)
   - FLAVOR and variant (determines the IP pool): `FMESH` / `fmesh`, `HSCON` / `hscon`, `HSSTA` / `hssta`
   - Device: `PE1` (testbed device alias)
   - Sequence number: unique within the variant; selects the /30 from its pool
   - Each negative TC differs from its baseline by exactly one condition (here, only `vrf-name` is omitted)

2. **Create service config template** (`config/<TC-ID>.cfg.j2`), the Full Mesh create payload without `vrf-name`:
   ```jinja2
   {# Full Mesh create payload with vrf-name omitted #}
   {
     "l3vpn:l3vpn": {
       "name": "{{ test_name }}",
       "variant": "full-mesh",
       "device": "{{ device_name }}",
       "vrf-description": "{{ vrf_description }}",
       "as-number": {{ as_number }},
       "rt-value": {{ rt_value }},
       "rd-value": "{{ rd_value }}",
       "interface-type-and-id": "{{ interface_type_and_id }}",
       "interface-description": "{{ interface_description }}",
       "interface-ip": "{{ interface_ip }}",
       "prefix-length": {{ prefix_length }},
       "dot1q": {{ dot1q }},
       "neighbor-ip": "{{ neighbor_ip }}",
       "remote-as": {{ remote_as }},
       "password": "{{ password }}",
       "as-override": {{ include_as_override | lower }}
     }
   }
   ```

   `password` is read from the `BGP_NEIGHBOR_PASSWORD` environment variable at render time; never put the secret in a template or testdata file.

3. **Create per-TC testdata** (`qa/03_cxta_automation/tests/L3VPN/NSO/testdata/<TC-ID>.yaml`):
   ```yaml
   tc_id: TC.L3VPN.NSO.SVC.FMESH.CRTE.MOD.DRYRUN.DEL.RLBK.0013
   inputs:
     variant: fmesh
     device: PE1
     sequence: 1
     test_name: QA-L3VPN-FMESH-001
     vrf_name: QA-FMESH-001   # not rendered (the template omits it); used to verify absence on PE1
     vrf_description: QA Full Mesh site 001
     as_number: "65001"
     rt_value: "101"
     rd_value: "65001:1001"
     include_as_override: true
   ```

4. **Expected result and preconfig:** a rejection TC has no golden config to compare when the expected outcome is that nothing is applied. Any prerequisite device state declared by Gate 2 gets a JSON `preconfig/<TC-ID>.pre.cfg`; mounted-NED nodes belong under `config` and are encoded as namespace-aware XML by the shared library.

5. **Create Robot script** (`scripts/<TC-ID>.robot`):
   ```robot
   *** Settings ***
   Documentation    Full Mesh: reject omission of vrf_name
   Library          ../../../../../../libraries/nso/NsoLib.py
   Resource         ../../../../../../keywords/nso/l3vpn_keywords.robot
   Suite Setup      Suite Setup L3VPN
   Test Tags        P0    FMESH    negative    CRTE

   *** Variables ***
   ${TC_ID}         TC.L3VPN.NSO.SVC.FMESH.CRTE.MOD.DRYRUN.DEL.RLBK.0013
   ${FLAVOR_DIR}    ${CURDIR}/..

   *** Test Cases ***
   Reject Full Mesh omission of vrf_name
       [Teardown]    Remove Service Instance
       Log Step    1    Submit the payload without vrf-name and expect rejection
       Assert L3VPN Service Rejected    ${TC_ID}    ${FLAVOR_DIR}
       Log Step    2    Verify nothing was applied to PE1
       ${context}=    Get Test Context
       Verify VRF Absent On Device    PE1    ${context}[vrf_name]

   *** Keywords ***
   Remove Service Instance
       ${context}=    Get Test Context
       IF    'test_name' in $context
           Delete Service If Exists    ${context}[test_name]
       END
   ```

   **Script quality (required):** no stubs (`Pass Execution`, TODO, log-only bodies); every LLD Expected Result → assertion; `Log Step` milestones only — no context dumps.

6. **Validate and test** (see Procedures 3 and 4)

### Procedure 3: Validate Template Syntax

**Use Case:** Verify all templates compile without Jinja2 syntax errors

**Python Validation Script:**
```python
#!/usr/bin/env python3
"""
Validate Jinja2 template syntax for CXTA test assets.
Run from: qa/03_cxta_automation/
"""

from jinja2 import Environment, FileSystemLoader, TemplateSyntaxError
import glob
import os
import sys

def validate_templates(base_dir='.'):
    """Validate all .j2 templates in the config/ and expected/ folders under tests/."""
    
    env = Environment(loader=FileSystemLoader(base_dir))
    errors = []
    valid_count = 0
    
    # Template folders in the mirrored layout:
    # qa/03_cxta_automation/tests/<SERVICE>/<PLATFORM>/<FUNCTION>/<FLAVOR>/{config,expected}/
    template_dirs = sorted(
        folder
        for kind in ('config', 'expected')
        for folder in glob.glob(os.path.join(base_dir, 'tests', '*', '*', '*', '*', kind))
    )
    if not template_dirs:
        print("No config/ or expected/ folders found under tests/")
        return 1
    
    for dir_path in template_dirs:
        if not os.path.exists(dir_path):
            print(f"⚠️  Directory not found: {dir_path}")
            continue
        
        for root, dirs, files in os.walk(dir_path):
            for file in files:
                if file.endswith('.j2'):
                    template_path = os.path.relpath(os.path.join(root, file), base_dir)
                    
                    try:
                        template = env.get_template(template_path)
                        valid_count += 1
                        print(f"✅ {template_path}")
                    except TemplateSyntaxError as e:
                        error_msg = f"{template_path}: {e.message} (line {e.lineno})"
                        errors.append(error_msg)
                        print(f"❌ {error_msg}")
                    except Exception as e:
                        error_msg = f"{template_path}: {str(e)}"
                        errors.append(error_msg)
                        print(f"❌ {error_msg}")
    
    # Summary
    print("\n" + "="*60)
    if errors:
        print(f"❌ VALIDATION FAILED: {len(errors)} template(s) with errors")
        print(f"✅ Valid templates: {valid_count}")
        for error in errors:
            print(f"   - {error}")
        return 1
    else:
        print(f"✅ ALL TEMPLATES VALID: {valid_count} templates checked")
        return 0

if __name__ == '__main__':
    sys.exit(validate_templates())
```

**Usage:**
```bash
cd qa/03_cxta_automation
source ../../.venv/bin/activate  # Use repository virtualenv
python3 -c "$(cat << 'EOF'
# Inline version of validation script above
from jinja2 import Environment, FileSystemLoader, TemplateSyntaxError
import glob
import os

env = Environment(loader=FileSystemLoader('.'))
errors, valid = [], 0

template_dirs = sorted(d for kind in ('config', 'expected') for d in glob.glob(f'tests/*/*/*/*/{kind}'))
for dir_path in template_dirs:
    for root, dirs, files in os.walk(dir_path):
        for file in [f for f in files if f.endswith('.j2')]:
            path = os.path.relpath(os.path.join(root, file))
            try:
                env.get_template(path)
                valid += 1
                print(f'✅ {path}')
            except TemplateSyntaxError as e:
                msg = f'{path}: {e.message} (line {e.lineno})'
                errors.append(msg)
                print(f'❌ {msg}')

print(f'\n{"❌ FAILED" if errors else "✅ VALID"}: {valid} templates, {len(errors)} errors')
EOF
)"
```

### Procedure 4: Test Template Rendering

**Use Case:** Verify templates render correctly with actual test context

**Interactive Testing in Python REPL:**
```bash
cd qa/03_cxta_automation
source ../../.venv/bin/activate
python3
```
```python
>>> from libraries.nso.NsoLib import NsoLib
>>> import json
>>> import yaml
>>> 
>>> # Initialize NsoLib and load testbed
>>> nso = NsoLib()
>>> nso.load_testbed('environments/testbed_l3vpn.yaml')
>>> 
>>> # Build test context from the TC's testdata
>>> tc_id = 'TC.L3VPN.NSO.SVC.HSSTA.CRTE.MOD.DRYRUN.DEL.RLBK.0001'
>>> base = 'tests/L3VPN/NSO'
>>> with open(f'{base}/testdata/{tc_id}.yaml') as f:
...     test_params = yaml.safe_load(f)['inputs']
...
>>> 
>>> context = nso.build_test_context(test_params)
>>> print("Generated Context:")
>>> # For fmesh, context['password'] is the BGP secret: never print it
>>> print(json.dumps({k: v for k, v in context.items() if k != 'password'}, indent=2))
{
  "variant": "hssta",
  "device": "PE1",
  "device_name": "pe0",
  "sequence": 1,
  "test_name": "QA-L3VPN-HSSTA-001",
  "vrf_name": "QA-HSSTA-001",
  "vrf_description": "QA Hub Static site 001",
  "as_number": "65102",
  "rt_value": "301",
  "rd_value": "65102:3001",
  "interface_ip": "192.168.120.1",
  "neighbor_ip": "192.168.120.2",
  "subnet": "255.255.255.252",
  "prefix_length": 30,
  "remote_as": "65002",
  "dot1q": "57",
  "mtu": 1500,
  "static_prefix": "10.50.0.0/24",
  "static_nexthop": "192.168.120.2",
  "include_as_override": false,
  "interface_type_and_id": "GigabitEthernet0/0/0/3.57",
  "interface_description": "PE-CE hssta site-001",
  "interface_id": "192.168.120.1"
}
>>> 
>>> # Render service config template
>>> cfg_rendered = nso.render_payload_template(
...     f'{base}/SVC/HSSTA/config/{tc_id}.cfg.j2',
...     context
... )
>>> print("\nRendered Service Config:")
>>> print(json.dumps(json.loads(cfg_rendered), indent=2))
>>> 
>>> # Render golden device config template
>>> expected_rendered = nso.render_expected_template(
...     f'{base}/SVC/HSSTA/expected/{tc_id}.expected.j2',
...     context
... )
>>> print("\nRendered Golden Device Config:")
>>> print(json.dumps(json.loads(expected_rendered), indent=2))
```

### Procedure 5: Manage IP Pool Capacity

**Use Case:** Verify testbed has sufficient IP capacity for all tests

**Check IP Pool Allocation:**

```python
#!/usr/bin/env python3
"""
Analyze IP pool capacity vs test case requirements.
Run from: qa/03_cxta_automation/
"""

import glob
import yaml
from collections import defaultdict

# Same aliases NsoLib.build_test_context() accepts
POOL_KEYS = {'fmesh': 'fmesh', 'full_mesh': 'fmesh', 'hscon': 'hscon',
             'hs_connected': 'hscon', 'hssta': 'hssta', 'hs_static': 'hssta'}

def check_ip_capacity(testbed_file='environments/testbed_l3vpn.yaml'):
    """Check that each pool has a /30 for the highest sequence its test cases use."""

    with open(testbed_file, 'r') as f:
        testbed = yaml.safe_load(f)

    ip_pools = testbed['testbed']['ip_pools']

    # Sequences per pool, from the per-TC testdata (inputs.variant / inputs.sequence)
    sequences = defaultdict(lambda: {0})
    for path in glob.glob('tests/*/*/testdata/*.yaml'):
        with open(path, 'r') as f:
            inputs = (yaml.safe_load(f) or {}).get('inputs', {})
        variant = inputs.get('variant', 'fmesh')
        sequences[POOL_KEYS.get(variant, variant)].add(int(inputs.get('sequence', 1)))
    
    # Report capacity
    print("="*60)
    print("IP POOL CAPACITY ANALYSIS")
    print("="*60)
    
    for variant, pool_list in ip_pools.items():
        allocated = len(pool_list)
        used = max(sequences[variant])  # highest sequence = number of /30s needed
        spare_pct = ((allocated - used) / allocated * 100) if allocated > 0 else 0
        
        status = "✅" if allocated >= used else "❌ INSUFFICIENT"
        
        print(f"\n{status} {variant}:")
        print(f"   Allocated: {allocated} /30 subnets ({allocated * 2} IPs)")
        print(f"   Needed: {used} /30 subnets (highest sequence in testdata)")
        print(f"   Spare: {allocated - used} subnets ({spare_pct:.0f}%)")
        
        if allocated < used:
            shortage = used - allocated
            print(f"   ⚠️  WARNING: Need {shortage} more /30 subnets!")
    
    print("\n" + "="*60)

if __name__ == '__main__':
    check_ip_capacity()
```

**Add More IPs to a Pool:**

Edit `environments/testbed_l3vpn.yaml`:
```yaml
testbed:
  ip_pools:
    hssta:
      # Add more /30 subnets sequentially
      - "192.168.120.0/30"
      - "192.168.120.4/30"
      - "192.168.120.8/30"
      - "192.168.120.12/30"
      - "192.168.120.16/30"
      - "192.168.120.20/30"
      - "192.168.120.24/30"  # NEW
      - "192.168.120.28/30"  # NEW
      # Continue incrementing by 4
```

## Troubleshooting

### Issue: Template Syntax Error

**Symptom:**
```
❌ tests/L3VPN/NSO/SVC/HSSTA/config/TC.L3VPN.NSO.SVC.HSSTA.CRTE.MOD.DRYRUN.DEL.RLBK.0001.cfg.j2: unexpected '}' (line 14)
```

**Diagnosis:**
- Jinja2 template has syntax error (mismatched braces, or a statement tag or comment tag left unclosed)

**Resolution:**
1. Open the template file
2. Check line number from error message
3. Common issues:
   - A single brace where a double-brace pair belongs (the example above opens `interface_ip` with double braces and closes it with one brace)
   - A variable-name typo is not a syntax error; it fails at render time as an undefined variable (next issue)
   - Missing closing brace
4. Fix and re-validate with Procedure 3

### Issue: Undefined Variable in Template

**Symptom:**
```
jinja2.exceptions.UndefinedError: 'vrf_description_modified' is undefined
```

**Diagnosis:**
- Template uses a variable that is not in the test context. NsoLib renders with strict undefined checking, and `build_test_context()` only knows the variables in the Template Variables table, so a typo in a name fails the same way

**Resolution:**
1. **Option A:** Fix the name if it is a typo (compare with the Template Variables table)

2. **Option B:** Add a default value in the template:
   ```jinja2
   "vrf-description": "{{ vrf_description_modified | default('QA modified site 001') }}"
   ```

3. **Option C:** For a standard variable, set it in the TC's testdata `inputs`:
   ```yaml
   inputs:
     variant: hssta
     device: PE1
     sequence: 1
     mtu: 9000  # ADD THIS
   ```

4. **Option D:** Change the testbed defaults (affects every TC):
   ```yaml
   testbed:
     test_data:
       defaults:
         mtu: 1500
   ```

5. A genuinely new variable needs `NsoLib.build_test_context()` extended (project-owned library); an unknown key in `inputs` is ignored

### Issue: IP Pool Exhaustion

**Symptom:**
```
ValueError: No available IPs in pool for variant 'hssta' sequence 99
```

**Diagnosis:**
- The TC's `sequence` is larger than the number of /30 subnets in that variant's pool (the pool entry at index `sequence - 1` is used)

**Resolution:**
1. Check current capacity (Procedure 5)
2. Add more /30 subnets to testbed YAML:
   ```yaml
   testbed:
     ip_pools:
       hssta:
         - "192.168.120.0/30"
         - "192.168.120.4/30"
         # Add more incrementing by 4
   ```
3. Ensure subnets don't overlap with other pools
4. Re-run validation

### Issue: Rendered Template is Invalid JSON/Config

**Symptom:**
Test fails with `JSONDecodeError`, "Invalid JSON" or an HTTP 400 from RESTCONF

**Diagnosis:**
- Template renders syntactically correct Jinja2 but produces invalid output

**Resolution:**
1. Test rendering in Python REPL (Procedure 4)
2. Inspect rendered output:
   ```python
   >>> cfg = nso.render_payload_template(f'{base}/SVC/HSSTA/config/{tc_id}.cfg.j2', context)
   >>> print(cfg)  # Look for issues
   >>> import json
   >>> json.loads(cfg)  # Will throw error if invalid JSON
   ```
3. Common issues:
   - Missing quotes around a string variable (e.g. `"rd-value": {{ rd_value }}` renders `65102:3001` unquoted)
   - Extra/missing commas in lists
   - Incorrect indentation in config blocks
4. Fix template, validate, re-test

### Issue: BGP Password Secret Not Set

**Symptom:**
```
RuntimeError: BGP_NEIGHBOR_PASSWORD is not set. The QA Executor must validate required secrets before Gate 4.
```

**Diagnosis:**
- A Full Mesh (`fmesh`) context needs the BGP password, which NsoLib reads from the `BGP_NEIGHBOR_PASSWORD` environment variable; other variants do not

**Resolution:**
1. Export `BGP_NEIGHBOR_PASSWORD` in the protected environment that runs the suite (CI secret or local shell), not in a template, testdata or testbed file
2. Do not print the context or the rendered Full Mesh payload, both contain the secret

## Integration with QA Agents

This skill is delegated to by the **`aifirst-nso-qa-builder`** agent (listed as "3 — dynamic templates" under its delegated skills; the `aifirst-nso-qa` orchestrator routes Builder requests there) during:

- **Gate 3, CXTA script generation**: the Builder generates `config/<TC-ID>.cfg.j2`, `config/<TC-ID>.patch.j2`, `expected/<TC-ID>.expected.j2` and per-TC testdata in the TCN-grammar-mirrored layout instead of static files
- **Gate 3, post-generation validation**: template syntax, rendering and IP pool capacity are checked (Procedures 3, 4 and 5)
- **Run time**: Robot Framework loads the testdata, builds the context from the testbed pools and renders the templates when the suite runs

The Builder:
- Generates `.cfg.j2`, `.patch.j2` and `.expected.j2` templates with the variables above
- Creates Robot scripts that use the project's L3VPN keywords (`Deploy L3VPN Service From Template`, `Verify Golden Device Config For TC`, `Assert L3VPN Service Rejected`, ...)
- Validates template syntax before presenting test assets
- Reports IP pool capacity in quality checks
- **Rejects stub scripts** — enforces assertions per LLD Expected Result and `Log Step` milestone logging only

## References

- **Agent Spec**: `../../agents/aifirst-nso-qa-builder.agent.md` (Gate 3: layout, generation rules, per-TC testdata)
- **Orchestrator**: `../../agents/aifirst-nso-qa.agent.md`
- **NsoLib**: `qa/03_cxta_automation/libraries/nso/NsoLib.py` (functions: `load_testbed`, `build_test_context`, `render_payload_template`, `render_expected_template`, `verify_device_config_matches_expected`)
- **L3VPN Keywords**: `qa/03_cxta_automation/keywords/nso/l3vpn_keywords.robot`
- **Testbed Format**: `qa/03_cxta_automation/environments/testbed_<spec-id>.yaml`
- **Jinja2 Documentation**: https://jinja.palletsprojects.com/

## Version History

- **1.1.0** (2026-10-06): Examples and layout aligned with the canonical `qa/03_cxta_automation/tests/<SERVICE>/<PLATFORM>/<FUNCTION>/<FLAVOR>/` tree, golden templates, per-TC testdata, and the real NsoLib context.
- **1.0.0** (2025-01-20): Initial skill documentation for dynamic template management
