# Robot Framework Basics

> Core concepts for writing `.robot` test files with CXTA.

---

## File Structure

Every `.robot` file (a "Test Suite") has these sections:

```robot
*** Settings ***
Library        CXTA
Resource       cxta.robot
Suite Setup    use testbed "testbed.yaml"

*** Variables ***
${nso}         nso
${device}      router1

*** Keywords ***
My Custom Keyword
    [Arguments]    ${arg1}    ${arg2}
    keyword1    ${arg1}
    keyword2    ${arg2}

*** Test Cases ***
My Test Case
    [Tags]    smoke    critical
    My Custom Keyword    value1    value2
```

### Settings Section

Required for every CXTA test:
```robot
Library      CXTA           # Load all CXTA keyword libraries
Resource     cxta.robot     # Load CXTA resource keywords
```

Optional settings:
```robot
Suite Setup       keyword-name                 # Runs before first test case
Suite Teardown    keyword-name                 # Runs after last test case
Test Setup        keyword-name                 # Runs before each test case
Test Teardown     keyword-name                 # Runs after each test case
Variables         testdata.yaml                # Load variables from YAML
Library           OperatingSystem              # Additional Robot libraries
Library           Collections                  # For list/dict operations
Force Tags        nso    service               # Tags on all test cases
```

### Variables Section

```robot
*** Variables ***
${scalar}       value                          # Scalar variable
@{list}         item1    item2    item3        # List variable
&{dict}         key1=val1    key2=val2         # Dictionary variable
```

### Test Cases Section

```robot
*** Test Cases ***
Descriptive Test Name
    [Tags]        tag1    tag2
    [Setup]       per-test setup keyword
    [Teardown]    per-test teardown keyword
    keyword1    arg1    arg2
    ${result}=    keyword2    arg1
    Should Contain    ${result}    expected
```

### Keywords Section

User-defined keywords (composable macros):
```robot
*** Keywords ***
Setup NSO Environment
    [Arguments]    ${testbed_file}=testbed.yaml
    use testbed "${testbed_file}"
    connect to device "${nso}"

Verify Service On Device
    [Arguments]    ${device}    ${expected_config}
    connect to device "${device}"
    ${output}=    execute command "show running-config" on device "${device}"
    Should Contain    ${output}    ${expected_config}
```

---

## Variable Types and Access

| Syntax | Type | Access |
|---|---|---|
| `${scalar}` | String/object | `${scalar}` |
| `@{list}` | List | `${list}[0]`, `@{list}` (expanded) |
| `&{dict}` | Dictionary | `${dict.key}`, `${dict}[key]` |

### Variables from YAML Files

Store complex data in YAML and load it in Settings:

```robot
Variables    testdata.yaml
```

```yaml
# testdata.yaml
nso: nso

service:
  name: test-l3vpn
  device: pe1
  interface: GigabitEthernet0/0/0/1
  ip_address: 10.0.0.1

service_payload: |
    <l3vpn xmlns="...">
      <name>test-l3vpn</name>
    </l3vpn>
```

Access: `${nso}`, `${service.name}`, `${service.device}`, `${service_payload}`

---

## Argument Passing

CXTA uses **embedded arguments** (quoted in the keyword pattern):
```robot
execute command "show version" on device "nso"
```

Robot builtins use **tabular arguments** (separated by 2+ spaces):
```robot
Should Contain    ${output}    expected_text
```

Minimum **two spaces** between keyword name and first argument, and between arguments.

---

## Control Flow

### FOR Loops
```robot
FOR    ${device}    IN    @{device_list}
    connect to device "${device}"
    ${output}=    execute command "show version" on device "${device}"
    Should Contain    ${output}    Version
END
```

### IF / ELSE
```robot
IF    '${status}' == 'active'
    Log    Service is active
ELSE IF    '${status}' == 'pending'
    Log    Service is pending
ELSE
    Fail    Unexpected status: ${status}
END
```

### TRY / EXCEPT (Robot 5+)
```robot
TRY
    via NSO REST API configure device "${nso}" at URI "${uri}" using "POST" with "xml" payload "${payload}"
EXCEPT    *error*
    Log    Service creation failed as expected
END
```

---

## Execution

```bash
# Run single test suite
robot test.robot

# Run all suites in directory
robot tests/

# Run with tag filter
robot --include smoke tests/
robot --exclude not-ready tests/

# Run with variables override
robot --variable nso:my-nso --variable CNC_HOST:10.0.0.1 tests/
```

Output files: `output.xml`, `log.html`, `report.html`
