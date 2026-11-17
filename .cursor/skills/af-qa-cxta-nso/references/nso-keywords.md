# NSO Keywords Reference

> Complete catalog of CXTA keywords from **NSO.py** and **NSORest.py** for NSO interaction.

---

## NSO CLI Keywords (NSO.py)

### Device Management

#### `add device "${device}" from NSO "${nso}" to testbed with credentials "${username}"/"${password}"`

Adds a device present in NSO to the pyATS testbed dynamically. Fetches IP/port/protocol from NSO config and creates a Unicon device entry. Replaces `127.0.0.1` with NSO's actual IP when devices are behind NSO.

```robot
add device "ce0" from NSO "nso" to testbed with credentials "${DEVICE_USER}"/"${DEVICE_PASSWORD}"
```

#### `add devices "${devices}" from NSO "${nso}" to testbed with credentials "${username}"/"${password}"`

Same as above but for multiple devices (semicolon-separated).

```robot
add devices "ce0;ce1;pe0;pe1" from NSO "nso" to testbed with credentials "${DEVICE_USER}"/"${DEVICE_PASSWORD}"
```

### Rollback Management

#### `retrieve latest NSO rollback number from "${nso}"`

Captures the current rollback number from NSO's commit history. Stores it internally for later use with `rollback NSO ... to rollback retrieved`. **Use in `[Setup]`** of every test that modifies NSO config.

```robot
[Setup]    retrieve latest NSO rollback number from "${nso}"
```

Returns the rollback number. Raises `CxtaException` if no rollback files found.

#### `rollback NSO "${nso}" to rollback "${number}"`

Rolls back NSO to a specific rollback number.

```robot
rollback NSO "nso" to rollback "42"
```

#### `rollback NSO "${nso}" to rollback retrieved`

Rolls back NSO to the number captured by `retrieve latest NSO rollback number`. **Use in `[Teardown]`** to clean up after tests. Detects if changes were actually made and skips if none.

```robot
[Teardown]    rollback NSO "${nso}" to rollback retrieved
```

Raises `CxtaException` if rollback number was never collected.

### CLI Error Handling

#### `ignore NSO CLI errors`

Disables NSO CLI error detection. By default, Unicon's NSO plugin catches patterns like `Error:`, `syntax error`, `Aborted`, `result false` and raises exceptions. Use this to test error scenarios.

```robot
ignore NSO CLI errors
${output}=    execute command "show configuration commit changes 9999" on device "nso"
Should Contain    ${output}    Error:
```

#### `check for NSO CLI errors`

Re-enables NSO CLI error detection (default patterns). Optionally pass a custom pattern list:

```robot
# Restore defaults
check for NSO CLI errors

# Custom patterns
@{patterns}=    Set Variable    Error:    Aborted
check for NSO CLI errors    ${patterns}
```

### CLI Style

#### `Set NSO cli style to "${style}"`

Switches NSO CLI between Cisco (`c`) and Juniper (`j`) style. Use before executing commands to match the NSO configuration.

```robot
Set NSO cli style to "j"
```

### Output Cleanup

#### `remove timestamps from NSO output "${output}"`

Replaces timestamps like `[ok][2017-12-12 20:30:14]` with `[ok][timestamp___removed]` for stable comparisons.

```robot
${clean}=    remove timestamps from NSO output "${raw_output}"
```

---

## NSO REST/RESTCONF Keywords (NSORest.py)

### REST API

#### `via NSO REST API configure device "${dev}" at URI "${uri}" using "${method}" with "${encoding}" payload "${payload}"`

Sends a REST request to NSO. Fails if response is not 2xx.

**Parameters:**
- `dev` — NSO device name from testbed
- `uri` — REST URI (e.g., `/api/running/services`)
- `method` — HTTP method: `POST`, `PATCH`, `PUT`, `DELETE`
- `encoding` — `xml` or `json`
- `payload` — Request body

**Returns:** `[status_code, response_text]`

```robot
${payload}=    Set Variable    <l3vpn xmlns="..."><name>test</name></l3vpn>
@{result}=     via NSO REST API configure device "nso" at URI "/api/running/services" using "POST" with "xml" payload "${payload}"
```

#### `via NSO REST API configure device "${dev}" at URI "${uri}" using "${method}" with "${encoding}" payload "${payload}" and expect "${expected_output}" in response`

Same as above but also checks that the response contains the expected string. Accepts 2xx and 4xx status codes (for testing expected errors).

```robot
@{result}=    via NSO REST API configure device "nso" at URI "/api/running/services" using "POST" with "xml" payload "${dup_payload}" and expect "data-exists" in response
```

#### `via NSO REST API retrieve "${uri}" from "${dev}" as "${encoding}"`

GET request against NSO REST API. Fails if response is not 2xx.

```robot
@{result}=    via NSO REST API retrieve "/api/running/devices/authgroups" from "nso" as "xml"
```

### RESTCONF API

#### `via NSO RESTCONF API configure device "${dev}" at URI "${uri}" using "${method}" with "${encoding}" payload "${payload}"`

Same as REST configure but uses RESTCONF headers (`application/yang-data`).

```robot
@{result}=    via NSO RESTCONF API configure device "nso" at URI "/restconf/data/tailf-ncs:devices/authgroups" using "POST" with "xml" payload "${payload}"
```

#### `via NSO RESTCONF API retrieve "${uri}" from "${dev}" as "${encoding}"`

GET against NSO RESTCONF API.

```robot
@{result}=    via NSO RESTCONF API retrieve "/restconf/data/tailf-ncs:devices/authgroups" from "nso" as "xml"
```

#### `via NSO RESTCONF API YANGPATCH configure device "${dev}" at URI "${uri}" using PATCH with "${encoding}" payload "${payload}"`

YANG PATCH per RFC 8072. Uses `application/yang-patch+xml/json` content type.

```robot
@{result}=    via NSO RESTCONF API YANGPATCH configure device "nso" at URI "/restconf/data/devices" using PATCH with "xml" payload "${yang_patch_payload}"
```

### Low-Level Access

#### `NSO interact via rest`

Full control over REST parameters. Does NOT auto-check status codes. Returns `[status_code, response_text]`.

```robot
@{result}=    NSO interact via rest    REST    nso    /api/running/services    GET    xml
@{result}=    NSO interact via rest    REST    nso    /api/running/services    POST    xml    ${payload}
@{result}=    NSO interact via rest    RESTCONF    nso    /restconf/data/foo    POST    json    ${payload}    {"Content-type": "custom/header"}
```

### Timeout

#### `set REST timeout to "${seconds}" seconds`

Sets timeout for all REST/RESTCONF calls. Default is 300 seconds. Returns previous timeout.

```robot
${old}=    set REST timeout to "60" seconds
```

---

## Important Notes

1. **REST vs RESTCONF URIs**: REST uses `/api/running/...`, RESTCONF uses `/restconf/data/...`
2. **Encoding**: Always specify `xml` or `json` — CXTA auto-derives Content-Type headers from the URI pattern
3. **Connection credentials**: REST/RESTCONF credentials come from the testbed's `rest`/`restconf` connection section
4. **Rollback commands use a separate CLI session** — they don't interfere with the test's NSO session
5. **The `${nso}` variable** is expected by many NSO keywords — always define it
