---
name: af-qa-cxta-nso
description: 'CXTA keyword catalog for triaging one failing NSO Robot keyword (Gate 5). Open a single references/*.md file only after a failure names that keyword. Do not open this skill while generating Robot scripts.'
---

# CXTA NSO Testing Skill

> Write CXTA (Robot Framework) test suites for testing NSO services — service CRUD, device config verification, REST/RESTCONF API validation, and rollback safety.

---

## When to Use This Skill

The QA Builder does not open this skill, `references/`, or `examples/` while generating scripts. Gate 3 is self-contained.

Open this skill only while triaging a CXTA failure, and then open only the one reference whose keyword the failure named.

---

## Reference Index

| Reference | Load When... |
|---|---|
| `references/robot-framework-basics.md` | Triage only — file anatomy is already in the failing `.robot` |
| `references/style-guide.md` | Triage only — a review asked for a convention |
| `references/testbed-config.md` | Triage only — the failure is in the testbed |
| `references/nso-keywords.md` | Triage only — the failure names an NSO CLI, REST, or RESTCONF keyword |
| `references/device-cli-keywords.md` | Triage only — the failure names a device-command keyword |
| `references/compare-keywords.md` | Triage only — the failure names a compare keyword |
| `references/templates-keywords.md` | Triage only — the failure names a template keyword |
| `references/custom-keywords.md` | Triage only — the failure is in a custom keyword |
| `references/common-patterns.md` | Triage only — the failure matches a rollback or data-driven pattern |

---

## Example Index

| Example | Demonstrates |
|---|---|
| `examples/01-basic-nso-cli.robot` | Connect to NSO, execute CLI commands, verify output |
| `examples/02-nso-rest-service.robot` | Create/delete NSO service via REST API with rollback protection |
| `examples/03-data-driven.robot` | YAML variables + Jinja2 templates for parameterized service tests |
| `examples/04-config-comparison.robot` | Before/after device config diff workflow |
| `examples/05-negative-testing.robot` | Error handling — expect failures, invalid payloads |
| `examples/testbed-nso.yaml` | Reference testbed with NSO + network devices |
| `examples/testdata.yaml` | Reference YAML test data with payloads and templates |

---

## Quick Start Pattern

Every NSO service test follows this structure:

```robot
*** Settings ***
Library        CXTA
Resource       cxta.robot
Suite Setup    Setup NSO
Variables      testdata.yaml

*** Test Cases ***
Create And Verify Service
    [Setup]     retrieve latest NSO rollback number from "${nso}"
    # Deploy service via REST
    via NSO REST API configure device "${nso}" at URI "/api/running/services" using "POST" with "xml" payload "${service_payload}"
    # Verify on device
    connect to device "${device}"
    ${output}=   execute command "show running-config" on device "${device}"
    Should Contain   ${output}   expected-config-line
    [Teardown]  rollback NSO "${nso}" to rollback retrieved

*** Keywords ***
Setup NSO
    use testbed "testbed.yaml"
    connect to device "nso"
    ${output}=   execute command "devices fetch-ssh-host-keys" on device "nso"
    Should Not Contain   ${output}   result false
    ${output}=   execute command "devices sync-from" on device "nso"
    Should Not Contain   ${output}   result false
```

### Key Rules
1. **Always use rollback** — `[Setup]` retrieves rollback number, `[Teardown]` restores it
2. **Quote all parameters** — `"${variable}"` not `${variable}`
3. **Testbed first** — `use testbed` must be called before any device interaction
4. **YAML for data** — Store payloads, templates, and expected values in `.yaml` files
5. **Parameterize everything** — No hardcoded IPs, device names, or service parameters in test cases
6. **Honor the repository runtime contract** — Read `Jenkinsfile`,
   `scripts/setup_nso_container.sh`, `scripts/netsim_simulation.sh`, and
   `scripts/pyats_robot_validation.sh` before writing a testbed. Endpoint
   variables are derived connection settings. Credential values stay in the
   runtime and are forwarded by name. Optional device-name variables keep the
   testbed default when unset.
7. **Self-validate** — Run `bash scripts/validate_cxta_pipeline_contract.sh`
   after generation. Fix failures before handing the suite to Jenkins.
8. **Use Jenkins-discoverable paths** — Generate under
   `qa/03_cxta_automation/tests/<SERVICE>/<PLATFORM>/...`; do not invent a
   test-owned runner or use an unprefixed `tests/<SERVICE>/...` tree.
9. **Match the library schema** — NSO fields are `url_env`, `host_env`,
   `port_env`, `username_env`, and `password_env`. Devices use `name`,
   optional `name_env`, and exact `ned_id`. Never use `user_env`.
10. **Freeze prerequisites before assets** — Write
    `qa/03_cxta_automation/environments/<spec-id>.runtime-contract.yaml` with
    the LLD fingerprint, pipeline variables, image/version source,
    device/NED mapping, prerequisite ownership, preconfig encoding, suite root,
    and Jenkins evidence path. No field may remain unresolved.
11. **Encode preconfig correctly** — Per-TC `.pre.cfg` files are JSON with
    `device` and `config`. Mounted-NED `config` is serialized as
    namespace-aware XML by `preconfig_xml.py`; do not PATCH mounted NED nodes
    as JSON under `tailf-ncs:config`.
