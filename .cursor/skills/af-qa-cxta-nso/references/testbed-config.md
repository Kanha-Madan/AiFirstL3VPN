# NSO Testbed Configuration

> How to define NSO and network devices in the pyATS testbed YAML file.

---

## Testbed Structure

The testbed YAML defines all devices, their connection details, and credentials. It must be loaded before any device interaction.

## Pipeline contract

Inspect `Jenkinsfile` and `scripts/setup_nso_container.sh`,
`scripts/netsim_simulation.sh`, and `scripts/pyats_robot_validation.sh` before
choosing fields. Generated repository testbeds record environment-variable
names, never credential values:

```yaml
testbed:
  nso:
    scheme: http
    url_env: NSO_RESTCONF_URL
    host_env: NSO_HOST
    port_env: NSO_PORT
    default_port: 8080
    username_env: NSO_RESTCONF_USER
    password_env: NSO_RESTCONF_PASSWORD
  devices:
    xr0:
      ned: cisco-iosxr
    service-device:
      name: xr75-0
      name_env: IPIC_DEVICE_NAME
      ned_id: cisco-iosxr-cli-7.75
```

`NSO_HOST`, `NSO_PORT`, and `NSO_RESTCONF_URL` are derived by the CXTA runner.
`name_env` is an optional override and falls back to `name` when unset. Only
password and token variables are secrets. Jenkins generates the disposable NSO
password once per build. Run `bash scripts/validate_cxta_pipeline_contract.sh`
after creating a testbed.

> The placeholders below are generic pyATS syntax only. Generated repository
> testbeds use `nso.username_env`, `nso.password_env`, and other `*_env`
> references, never credential values.

```yaml
testbed:
  credentials:
    default:
      username: <runtime-user>
      password: <runtime-password>

devices:
  nso:
    type: nso
    os: nso
    credentials:
      default:
        username: <runtime-user>
        password: <runtime-password>
    connections:
      defaults:
        class: unicon.Unicon
        via: cli
      cli:
        protocol: ssh
        ip: 127.0.0.1
        port: 2024
        settings:
          IGNORE_CHATTY_TERM_OUTPUT: True
      rest:
        protocol: http
        ip: 127.0.0.1
        port: 8080
        username: <runtime-user>
        password: <runtime-password>
      restconf:
        protocol: https
        ip: 127.0.0.1
        port: 8888
        username: <runtime-user>
        password: <runtime-password>
```

---

## Key Rules

### Device Name

- For network devices: the hostname **must match** the device name in the YAML
- For NSO: any name is fine, but it must match the `${nso}` variable in your test

### Connection Types

| Connection | Purpose | Required Fields |
|---|---|---|
| `cli` | SSH CLI access | `protocol`, `ip`, `port` |
| `rest` | REST API access | `protocol`, `ip`, `port`, `username`, `password` |
| `restconf` | RESTCONF API | `protocol`, `ip`, `port`, `username`, `password` |

### Defaults

- `defaults.via` — which connection to use when `connect to device` is called without `via`
- `defaults.class` — always `unicon.Unicon`

### IGNORE_CHATTY_TERM_OUTPUT

NSO logs commit messages to all CLI sessions. Add this setting to prevent them from contaminating command output:

```yaml
      cli:
        settings:
          IGNORE_CHATTY_TERM_OUTPUT: True
```

---

## Network Devices

### IOS-XR Router
```yaml
  pe1:
    type: router
    os: iosxr
    credentials:
      default:
        username: <runtime-user>
        password: <runtime-password>
    connections:
      defaults:
        class: unicon.Unicon
      cli:
        protocol: ssh
        ip: 10.0.0.1
        port: 22
```

### IOS Router
```yaml
  ce1:
    type: router
    os: ios
    credentials:
      default:
        username: <runtime-user>
        password: <runtime-password>
    connections:
      defaults:
        class: unicon.Unicon
      cli:
        protocol: ssh
        ip: 10.0.0.2
```

### Linux Server
```yaml
  jump-host:
    type: server
    os: linux
    credentials:
      default:
        username: <runtime-user>
        password: <runtime-password>
    connections:
      defaults:
        class: unicon.Unicon
      cli:
        protocol: ssh
        ip: 10.0.0.100
```

---

## Multiple Connections

When a device has multiple connections, specify `via` when connecting:

```robot
connect to device "nso" via "cli"
connect to device "nso" via "rest"
```

Or set default in testbed:
```yaml
    connections:
      defaults:
        via: cli
```

---

## Dynamic Device Addition

Add devices discovered through NSO to the testbed at runtime:

```robot
add device "ce0" from NSO "nso" to testbed with credentials "${DEVICE_USER}"/"${DEVICE_PASSWORD}"
add devices "ce0;ce1;pe0;pe1" from NSO "nso" to testbed with credentials "${DEVICE_USER}"/"${DEVICE_PASSWORD}"
```

This fetches IP/port/protocol from NSO and creates the pyATS device entry dynamically. Useful for netsim or NFV environments where device attributes aren't known at test-time.

---

## Loading the Testbed

```robot
# Explicit path
use testbed "testbed.yaml"

# Or equivalently
load testbed "testbed.yaml"

# Default location (/tmp/testbed.yaml — used by CXTM)
load testbed
```
