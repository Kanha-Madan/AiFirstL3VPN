# CXTA Style Guide

> Coding conventions for writing CXTA Robot Framework tests.

---

## Naming Conventions

### Test Suite Files
- Use descriptive names: `create_l3vpn_services.robot`, `verify_fabric_sync.robot`
- Prefix with numbers for execution order: `001_setup.robot`, `002_deploy.robot`, `003_verify.robot`
- Robot derives suite name from filename: `create_l3vpn_services.robot` → "Create L3vpn Services"

### Test Cases
- Descriptive, human-readable names
- Include test case ID if linked to ATP: `TC12345 - Verify L3VPN with static routing`
- Use present tense: "Create Service", "Verify Config", "Delete Service"

### Keywords
- One function per keyword — single responsibility
- Descriptive names that read like sentences
- Quote all embedded parameters: `Check if "${interface}" is "${state}"`

### Variables
- Descriptive names with comments: `${ipv4_addresses}` not `${result}`
- Global variables at top of file for easy modification
- Use YAML files for complex or structured data

---

## Structure Rules

1. **Settings section first** — Library imports, testbed, setup/teardown
2. **Variables section** — Inline definitions
3. **Keywords section** — User-defined keywords before test cases
4. **Test Cases section** — Actual tests last

## Parameterization

- **Always parameterize**: device names, IPs, interfaces, service names, ports
- **Never hardcode** deployment-specific values in test cases
- **Use YAML files** for payloads, templates, and expected values
- **Use Jinja2 templates** for dynamic payload generation

## Comments

- Add comments to explain "why", not "what"
- Comment above each variable explaining its purpose
- Comment complex keyword sequences

## Whitespace

- **Minimum 2 spaces** between keyword and arguments
- **4 spaces** for keyword body indentation (standard)
- **Tabs vs spaces**: be consistent, prefer spaces
- Whitespace is syntactically significant in Robot Framework

## Tags

```robot
*** Settings ***
Force Tags    nso    l3vpn              # Applied to all test cases

*** Test Cases ***
Create L3VPN Service
    [Tags]    smoke    critical          # Per-test tags
    ...

Unfinished Test
    [Tags]    not-ready                  # Exclude with --exclude not-ready
    ...
```

Use tags for:
- Feature grouping (`l3vpn`, `l2vpn`, `fabric`)
- Test maturity (`smoke`, `regression`, `not-ready`)
- Criticality (`critical`, `non-critical`)
- Environment (`lab`, `staging`)

## Guiding Principles

1. Keep test cases simple and human-readable
2. One feature/function check per test case
3. Avoid complex looping unless absolutely needed
4. Enforce deterministic behavior — same result every run
5. Use built-in Robot keywords where applicable
6. Download `log.html` for detailed troubleshooting
7. Parameterize for portability across environments
8. Share tests with your peers — readability matters
