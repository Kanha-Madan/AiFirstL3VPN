*** Settings ***
Documentation    Basic NSO CLI connectivity and device management.
...              Demonstrates: testbed loading, NSO connection, CLI commands,
...              fetch-keys, sync-from, and device command execution.
Library          CXTA
Resource         cxta.robot
Suite Setup      Setup NSO
Suite Teardown   disconnect from device "nso"

*** Variables ***
${nso}    nso

*** Test Cases ***
Fetch SSH Host Keys
    [Documentation]    Fetch host keys from all managed devices.
    ${output}=    execute command "devices fetch-ssh-host-keys" on device "${nso}"
    Should not contain    ${output}    result false

Sync From Devices
    [Documentation]    Synchronize device configs into NSO CDB.
    ${output}=    execute command "devices sync-from" on device "${nso}"
    Should not contain    ${output}    result false

Check Device Sync Status
    [Documentation]    Verify all devices are in sync.
    ${output}=    execute command "devices check-sync" on device "${nso}"
    Should not contain    ${output}    out-of-sync

Show Device Config Via NSO CLI
    [Documentation]    Retrieve device running-config through NSO.
    ${output}=    execute command "show running-config devices device pe1 config" on device "${nso}"
    Should Contain    ${output}    interface

Execute Command On Network Device
    [Documentation]    Connect to a network device and run a command.
    connect to device "pe1"
    ${output}=    execute command "show ip interface brief" on device "pe1"
    Log    ${output}
    disconnect from device "pe1"

*** Keywords ***
Setup NSO
    use testbed "testbed-nso.yaml"
    connect to device "${nso}"
