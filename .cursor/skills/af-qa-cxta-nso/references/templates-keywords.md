# Template Keywords Reference

> Keywords from **Templates.py** for rendering dynamic payloads and configuration from templates.

---

## Jinja2 Templates

### `render jinja2 template "${template_string}" with data "${data}"`

Renders a Jinja2 template string using a dictionary of variables. Returns the rendered string.

- `template_string`: Jinja2 template content as a string
- `data`: Python dictionary of variables

```robot
*** Test Cases ***
Render Inline Template
    ${data}=    Create Dictionary    name=test-vpn    vlan=100
    ${result}=    render jinja2 template "interface {{ name }}\n vlan {{ vlan }}" with data "${data}"
```

### `render jinja2 template from file "${template_file}" with data "${data}"`

Renders a Jinja2 template loaded from a file. The template file path is relative to the test execution directory.

```robot
*** Test Cases ***
Render Template From File
    ${data}=    Evaluate    yaml.safe_load(open("testdata.yaml"))    yaml
    ${payload}=    render jinja2 template from file "templates/service.xml.j2" with data "${data}"
    via NSO REST API configure "/api/running" on device "${nso}" with payload "${payload}"
```

---

## Python String Templates

### `render python modulo template "${template}" with data "${data}"`

Uses Python's `%` string formatting. Variables referenced as `%(name)s`.

```robot
${result}=    render python modulo template "Hello %(name)s, VLAN %(vlan)s" with data "${data}"
```

### `render python format template "${template}" with data "${data}"`

Uses Python's `.format()` string formatting. Variables referenced as `{name}`.

```robot
${result}=    render python format template "Hello {name}, VLAN {vlan}" with data "${data}"
```

### `render python string template "${template}" with data "${data}"`

Uses Python's `string.Template`. Variables referenced as `$name` or `${name}`.

```robot
${result}=    render python string template "Hello $name, VLAN $vlan" with data "${data}"
```

---

## Common Patterns

### YAML Data + Jinja2 Template

The most common pattern: load test data from YAML, render XML payload with Jinja2, send to NSO.

```robot
*** Settings ***
Library    CXTA
Resource   cxta.robot
Variables  testdata.yaml

*** Test Cases ***
Create Service From Template
    ${payload}=    render jinja2 template from file "templates/l3vpn.xml.j2" with data "${service}"
    via NSO REST API configure "/api/running/services/l3vpn" on device "${nso}" with payload "${payload}"
```

### Template File Example (`templates/l3vpn.xml.j2`)

```xml
<l3vpn xmlns="http://example.com/l3vpn">
  <name>{{ name }}</name>
  <vrf>{{ vrf }}</vrf>
  {% for endpoint in endpoints %}
  <endpoint>
    <device>{{ endpoint.device }}</device>
    <interface>{{ endpoint.interface }}</interface>
    <ip-address>{{ endpoint.ip }}</ip-address>
  </endpoint>
  {% endfor %}
</l3vpn>
```
