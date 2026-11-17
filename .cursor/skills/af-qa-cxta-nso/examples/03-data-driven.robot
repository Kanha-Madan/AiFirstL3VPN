*** Settings ***
Documentation    Data-driven testing: YAML variables + Jinja2 template rendering.
...              Demonstrates: Variables from YAML, Jinja2 template rendering,
...              service creation from template, parameterized test data.
Library          CXTA
Resource         cxta.robot
Suite Setup      Setup NSO
Suite Teardown   disconnect from device "nso"

Variables        testdata.yaml

*** Test Cases ***
Create Service From Template
    [Documentation]    Render a Jinja2 template with YAML data and deploy.
    [Setup]       retrieve latest NSO rollback number from "${nso}"
    ${payload}=    render jinja2 template "${service_template}" with variables "${service1}"
    Log    Rendered payload: ${payload}
    via NSO REST API configure device "${nso}" at URI "/api/running/services" using "POST" with "xml" payload "${payload}"
    [Teardown]    rollback NSO "${nso}" to rollback retrieved

Create Service With Inline Template
    [Documentation]    Use an inline Jinja2 template string.
    [Setup]       retrieve latest NSO rollback number from "${nso}"
    ${template}=    Set Variable    <greTunnel><name>{{ name }}</name><tunnel-name>{{ tunnel_id }}</tunnel-name><src-device>{{ src }}</src-device><dest-device>{{ dst }}</dest-device></greTunnel>
    ${data}=    Create Dictionary    name=inline-test    tunnel_id=2000    src=iosv-1    dst=iosv-2
    ${payload}=    render jinja2 template "${template}" with variables "${data}"
    via NSO REST API configure device "${nso}" at URI "/api/running/services" using "POST" with "xml" payload "${payload}"
    [Teardown]    rollback NSO "${nso}" to rollback retrieved

*** Keywords ***
Setup NSO
    use testbed "testbed-nso.yaml"
    connect to device "${nso}"
    ${output}=    execute command "devices fetch-ssh-host-keys" on device "${nso}"
    Should not contain    ${output}    result false
    ${output}=    execute command "devices sync-from" on device "${nso}"
    Should not contain    ${output}    result false
