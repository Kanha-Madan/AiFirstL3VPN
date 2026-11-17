*** Settings ***
Documentation    Config comparison workflow: before/after diff with CiscoConfDiff.
...              Demonstrates: config snapshot collection, CiscoConfDiff comparison,
...              reference diff matching, continue on failure.
Library          CXTA
Resource         cxta.robot
Library          OperatingSystem
Suite Setup      Setup NSO
Suite Teardown   disconnect from device "nso"

Variables        testdata.yaml

*** Test Cases ***
Verify Service Creates Expected Config Changes
    [Documentation]    Deploy a service, diff device configs, compare against expected diffs.
    [Setup]       retrieve latest NSO rollback number from "${nso}"
    collect "before" config from "${service1.src_device}"
    collect "before" config from "${service1.dest_device}"
    ${payload}=    render jinja2 template "${service_template}" with variables "${service1}"
    via NSO REST API configure device "${nso}" at URI "/api/running/services" using "POST" with "xml" payload "${payload}"
    collect "after" config from "${service1.src_device}"
    collect "after" config from "${service1.dest_device}"
    continue on failure enabled
    compare configs from "${service1.src_device}" and compare with "${service1_diffs.src}"
    compare configs from "${service1.dest_device}" and compare with "${service1_diffs.dest}"
    continue on failure disabled
    [Teardown]    rollback NSO "${nso}" to rollback retrieved

*** Keywords ***
collect "${state}" config from "${device}"
    [Documentation]    Connect to device, capture running config, save to file.
    connect to device "${device}"
    ${output}=    execute command "show running-config" on device "${device}"
    Create File    ${device}-${state}.txt    ${output}

compare configs from "${device}" and compare with "${expected_diffs}"
    [Documentation]    CiscoConfDiff comparison with expected reference diffs.
    use ciscoconfdiff to compare ios configs "${device}-before.txt" and "${device}-after.txt"
    compare latest ciscoconfdiff with reference diffs in "@{expected_diffs}[0]" and "@{expected_diffs}[1]"

Setup NSO
    use testbed "testbed-nso.yaml"
    connect to device "${nso}"
    ${output}=    execute command "devices fetch-ssh-host-keys" on device "${nso}"
    Should not contain    ${output}    result false
    ${output}=    execute command "devices sync-from" on device "${nso}"
    Should not contain    ${output}    result false
