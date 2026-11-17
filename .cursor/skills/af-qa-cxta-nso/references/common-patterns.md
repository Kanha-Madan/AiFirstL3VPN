# Common NSO Testing Patterns

> Recurring patterns for NSO service testing with CXTA.

---

## Pattern 1: Suite Setup — Connect and Sync

Every NSO test suite starts by loading the testbed, connecting to NSO, and syncing devices.

```robot
*** Settings ***
Library        CXTA
Resource       cxta.robot
Suite Setup    Setup NSO
Suite Teardown    disconnect from device "nso"

*** Keywords ***
Setup NSO
    use testbed "testbed.yaml"
    connect to device "nso"
    ${output}=    execute command "devices fetch-ssh-host-keys" on device "nso"
    Should not contain    ${output}    result false
    ${output}=    execute command "devices sync-from" on device "nso"
    Should not contain    ${output}    result false
```

---

## Pattern 2: Rollback Setup/Teardown

Save the rollback point before each test, restore after. Ensures tests are independent.

```robot
*** Test Cases ***
Create Service
    [Setup]       retrieve latest NSO rollback number from "${nso}"
    # ... test body ...
    [Teardown]    rollback NSO "${nso}" to rollback retrieved
```

---

## Pattern 3: REST API Service CRUD

Create, verify, and delete a service via NSO REST API.

```robot
*** Test Cases ***
Create And Verify Service
    [Setup]       retrieve latest NSO rollback number from "${nso}"
    via NSO REST API configure device "${nso}" at URI "/api/running/services" using "POST" with "xml" payload "${service_payload}"
    ${result}=    via NSO REST API retrieve device "${nso}" at URI "/api/running/services/my-service{test-svc}" using "GET" as "xml"
    Should Contain    ${result}    test-svc
    [Teardown]    rollback NSO "${nso}" to rollback retrieved
```

---

## Pattern 4: RESTCONF API Usage

Use RESTCONF for YANG-modeled access. URI format differs from REST.

```robot
*** Test Cases ***
Configure Via RESTCONF
    [Setup]       retrieve latest NSO rollback number from "${nso}"
    via NSO RESTCONF API configure device "${nso}" at URI "/restconf/data/services" using "POST" with "xml" payload "${service_payload}"
    ${result}=    via NSO RESTCONF API retrieve device "${nso}" at URI "/restconf/data/services/my-service=test-svc" using "GET" as "xml"
    [Teardown]    rollback NSO "${nso}" to rollback retrieved
```

---

## Pattern 5: Data-Driven with YAML + Jinja2

Separate test data from test logic. YAML has parameters, Jinja2 template generates payloads.

```robot
*** Settings ***
Variables    testdata.yaml

*** Test Cases ***
Create Service From Template
    [Setup]       retrieve latest NSO rollback number from "${nso}"
    ${payload}=    render jinja2 template "${service_template}" with variables "${service1}"
    via NSO REST API configure device "${nso}" at URI "/api/running/services" using "POST" with "xml" payload "${payload}"
    [Teardown]    rollback NSO "${nso}" to rollback retrieved
```

**testdata.yaml:**
```yaml
nso: nso

service1:
  name: test-svc
  vlan: 100
  device: pe1

service_template: |
    <my-service>
      <name>{{ name }}</name>
      <vlan>{{ vlan }}</vlan>
      <device>{{ device }}</device>
    </my-service>
```

---

## Pattern 6: Config Comparison Workflow

Verify that a service creates the expected device configuration changes.

```robot
*** Test Cases ***
Verify Service Config Changes
    [Setup]       retrieve latest NSO rollback number from "${nso}"
    collect "before" config from "${device}"
    ${payload}=    render jinja2 template "${service_template}" with variables "${service1}"
    via NSO REST API configure device "${nso}" at URI "/api/running/services" using "POST" with "xml" payload "${payload}"
    collect "after" config from "${device}"
    compare configs from "${device}" and compare with "${expected_diffs}"
    [Teardown]    rollback NSO "${nso}" to rollback retrieved

*** Keywords ***
collect "${state}" config from "${device}"
    connect to device "${device}"
    ${output}=    execute command "show running-config" on device "${device}"
    Create File    ${device}-${state}.txt    ${output}

compare configs from "${device}" and compare with "${expected_diffs}"
    use ciscoconfdiff to compare ios configs "${device}-before.txt" and "${device}-after.txt"
    compare latest ciscoconfdiff with reference diffs in "@{expected_diffs}[0]" and "@{expected_diffs}[1]"
```

---

## Pattern 7: Negative Testing

Verify that invalid input is rejected by NSO.

```robot
*** Test Cases ***
Reject Invalid Service Payload
    [Setup]       retrieve latest NSO rollback number from "${nso}"
    Run Keyword and Expect Error    *    via NSO REST API configure device "${nso}" at URI "/api/running/services" using "POST" with "xml" payload "${invalid_payload}"
    [Teardown]    rollback NSO "${nso}" to rollback retrieved
```

A bare `*` only proves that something failed. For project suites, also assert the status and an error text that names the omitted input, accepting any of its YANG leaves because NSO reports only the first missing leaf (see the Builder's Response contracts).

---

## Pattern 8: Multi-Device Verification

After deploying a service, verify config on all affected devices.

```robot
*** Test Cases ***
Verify Service On Multiple Devices
    [Setup]       retrieve latest NSO rollback number from "${nso}"
    via NSO REST API configure device "${nso}" at URI "/api/running/services" using "POST" with "xml" payload "${payload}"
    FOR    ${device}    IN    @{affected_devices}
        connect to device "${device}"
        ${output}=    execute command "show running-config interface Tunnel1000" on device "${device}"
        Should Contain    ${output}    Tunnel1000
    END
    [Teardown]    rollback NSO "${nso}" to rollback retrieved
```

---

## Pattern 9: CLI Commands on NSO

Execute NSO CLI commands directly (not REST API).

```robot
*** Test Cases ***
Show Service Status Via CLI
    ${output}=    execute command "show services my-service test-svc" on device "nso"
    Should Contain    ${output}    reached

Check Device Sync Status
    ${output}=    execute command "devices check-sync" on device "nso"
    Should not contain    ${output}    out-of-sync
```

---

## Pattern 10: Continue on Failure

When you need to verify multiple things and want all failures reported (not just the first).

```robot
*** Test Cases ***
Verify All Endpoints
    continue on failure enabled
    Verify Endpoint    ${device1}    Tunnel1000    20.0.0.1
    Verify Endpoint    ${device2}    Tunnel1000    20.0.0.2
    continue on failure disabled
```
