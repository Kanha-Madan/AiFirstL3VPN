*** Settings ***
Documentation    Negative testing and error handling patterns.
...              Demonstrates: Run Keyword and Expect Error, ignore NSO CLI errors,
...              checking for errors, continue on failure.
Library          CXTA
Resource         cxta.robot
Suite Setup      Setup NSO
Suite Teardown   disconnect from device "nso"

Variables        testdata.yaml

*** Test Cases ***
Reject Invalid Service Payload
    [Documentation]    Verify that NSO rejects a malformed payload.
    [Setup]       retrieve latest NSO rollback number from "${nso}"
    Run Keyword and Expect Error    *    via NSO REST API configure device "${nso}" at URI "/api/running/services" using "POST" with "xml" payload "${negative_service_payload}"
    [Teardown]    rollback NSO "${nso}" to rollback retrieved

Verify Error Contains Expected Message
    [Documentation]    Catch the error and verify its content.
    [Setup]       retrieve latest NSO rollback number from "${nso}"
    ${error}=    Run Keyword and Expect Error    *    via NSO REST API configure device "${nso}" at URI "/api/running/services" using "POST" with "xml" payload "${negative_service_payload}"
    Should Contain    ${error}    error
    [Teardown]    rollback NSO "${nso}" to rollback retrieved

Ignore CLI Errors Temporarily
    [Documentation]    Use ignore/check CLI errors for commands that may fail.
    ignore NSO CLI errors on device "${nso}"
    ${output}=    execute command "show nonexistent" on device "${nso}"
    Log    Output (may contain error): ${output}
    check for NSO CLI errors on device "${nso}"

Continue On Failure For Multiple Checks
    [Documentation]    Report all failures instead of stopping at first.
    [Setup]       retrieve latest NSO rollback number from "${nso}"
    via NSO REST API configure device "${nso}" at URI "/api/running/services" using "POST" with "xml" payload "${service_payload}"
    continue on failure enabled
    ${r1}=    via NSO REST API retrieve device "${nso}" at URI "/api/running/services/greTunnel{test-tunnel}" using "GET" as "xml"
    Should Contain    ${r1}    test-tunnel
    Should Contain    ${r1}    src-device
    Should Contain    ${r1}    dest-device
    continue on failure disabled
    [Teardown]    rollback NSO "${nso}" to rollback retrieved

*** Keywords ***
Setup NSO
    use testbed "testbed-nso.yaml"
    connect to device "${nso}"
    ${output}=    execute command "devices fetch-ssh-host-keys" on device "${nso}"
    Should not contain    ${output}    result false
    ${output}=    execute command "devices sync-from" on device "${nso}"
    Should not contain    ${output}    result false
