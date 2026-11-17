*** Settings ***
Documentation    NSO REST API service lifecycle: create, verify, rollback.
...              Demonstrates: REST API configure/retrieve, rollback pattern,
...              negative testing with Run Keyword and Expect Error.
Library          CXTA
Resource         cxta.robot
Suite Setup      Setup NSO
Suite Teardown   disconnect from device "nso"

Variables        testdata.yaml

*** Test Cases ***
Create Service Via REST
    [Documentation]    Create a service using REST API POST and verify it exists.
    [Setup]       retrieve latest NSO rollback number from "${nso}"
    via NSO REST API configure device "${nso}" at URI "/api/running/services" using "POST" with "xml" payload "${service_payload}"
    ${result}=    via NSO REST API retrieve device "${nso}" at URI "/api/running/services/greTunnel{test-tunnel}" using "GET" as "xml"
    Should Contain    ${result}    test-tunnel
    [Teardown]    rollback NSO "${nso}" to rollback retrieved

Retrieve Service List
    [Documentation]    Retrieve the service list from NSO REST API.
    ${result}=    via NSO REST API retrieve device "${nso}" at URI "/api/running/services" using "GET" as "xml"
    Log    ${result}

Reject Invalid Payload
    [Documentation]    Verify that an invalid payload is rejected by NSO.
    [Setup]       retrieve latest NSO rollback number from "${nso}"
    Run Keyword and Expect Error    *    via NSO REST API configure device "${nso}" at URI "/api/running/services" using "POST" with "xml" payload "${negative_service_payload}"
    [Teardown]    rollback NSO "${nso}" to rollback retrieved

*** Keywords ***
Setup NSO
    use testbed "testbed-nso.yaml"
    connect to device "${nso}"
    ${output}=    execute command "devices fetch-ssh-host-keys" on device "${nso}"
    Should not contain    ${output}    result false
    ${output}=    execute command "devices sync-from" on device "${nso}"
    Should not contain    ${output}    result false
