# NSO Package Types — ncs-make-package Reference

Source: https://nso-docs.cisco.com/guides/resources/man/ncs-make-package.1

> For a full config-driven service generation workflow (YANG design, `load-native-config` template generation, interface type enumeration, Python authoring, and end-to-end testing), see [service-from-config.md](./service-from-config.md).

---

## Service Package Skeletons (`--service-skeleton`)

| Skeleton | What it creates | Best for |
|---|---|---|
| `python` | Python service code only, no template | Logic-heavy services |
| `python-and-template` | Python service code + XML device template | Most services (recommended) |
| `template` | XML device template only, no code | Simple, purely declarative services |
| `java` | Java service code only | Java-based services |
| `java-and-template` | Java service code + XML template | Java services with templates |
| `nano-python-and-template` | Nano service with plan + Python + template | Multi-stage services with state tracking |

### Common flags for service skeletons

```bash
--augment /ncs:services       # Place service model under /ncs:services (standard)
--root-container NAME         # Wrap model in a container named NAME
--component-class module.Class  # Python class name (default: main.Main)
--action-example              # Add an example Action to the skeleton
--subscriber-example          # Add an example CDB subscriber
--no-test                     # Skip generating the test/ directory
```

---

## NED Package Types

### NETCONF NED (from YANG files)

```bash
ncs-make-package \
  --netconf-ned /path/to/device/yang-files \
  --dest packages/acme-router \
  acme-router

# Build
cd packages/acme-router/src && make all
```

Flags:
```
--yanger-sanitize            # Sanitize/fix device YANG files
--no-netsim                  # Don't create a netsim directory
--no-java                    # Skip Java class generation
--no-python                  # Skip Python class generation
--no-template                # Skip template generation
--vendor VENDOR              # Set vendor in package-meta-data.xml
--package-version VERSION    # Set version in package-meta-data.xml
--ncs-depend-package DIR     # Depend on another package (relative to src/)
--confd-netsim-db-mode MODE  # candidate|startup|running-only (default: candidate)
```

### LSA NETCONF NED (lower NSO as a device)

```bash
ncs-make-package \
  --lsa-netconf-ned /path/to/lower-nso-yang \
  --lsa-lower-nso cisco-nso-nc-6.7 \
  --dest packages/lower-nso-ned \
  lower-nso-ned
```

### SNMP NED (from MIB files)

```bash
ncs-make-package \
  --snmp-ned /path/to/mib-files \
  --dest packages/acme-snmp \
  acme-snmp
```

### Generic NED skeleton

```bash
ncs-make-package \
  --generic-ned-skeleton \
  --dest packages/my-generic-ned \
  my-generic-ned
```

---

## Other Package Types

### Data provider skeleton

```bash
ncs-make-package \
  --data-provider-skeleton \
  --dest packages/my-data-provider \
  my-data-provider
```

### Erlang skeleton

```bash
ncs-make-package \
  --erlang-skeleton \
  --erlang-application-name my-app \
  --dest packages/my-erlang-pkg \
  my-erlang-pkg
```

---

## package-meta-data.xml

Always update this file after scaffolding:

```xml
<ncs-package xmlns="http://tail-f.com/ns/ncs-packages">
  <name>my-svc</name>
  <package-version>1.0</package-version>
  <description>My service package</description>
  <ncs-min-version>5.0</ncs-min-version>
  <component>
    <name>my-svc</name>
    <application>
      <python-class-name>my_svc.main.Main</python-class-name>
    </application>
  </component>
</ncs-package>
```

---

## YANG Model Patterns

### Minimal service model

```yang
module my-svc {
  namespace "http://com/example/my-svc";
  prefix my-svc;

  import ietf-inet-types { prefix inet; }
  import tailf-ncs { prefix ncs; }

  list my-svc {
    key name;
    uses ncs:service-data;
    ncs:servicepoint "my-svc-servicepoint";

    leaf name {
      type string;
    }

    // Add service inputs here
    leaf device {
      type leafref {
        path "/ncs:devices/ncs:device/ncs:name";
      }
    }

    leaf vlan-id {
      type uint16 {
        range "1..4094";
      }
    }
  }
}
```

### Service model with interface type enumeration

Use this pattern when the service supports multiple interface types (identified in Step 2b of the service-from-config workflow):

```yang
module my-svc {
  namespace "http://example.com/nso/my-svc";
  prefix my-svc;

  import ietf-inet-types { prefix inet; }
  import tailf-common   { prefix tailf; }
  import tailf-ncs      { prefix ncs; }

  list my-svc {
    key name;
    uses ncs:service-data;
    ncs:servicepoint "my-svc-servicepoint";

    leaf name {
      tailf:info "Unique service instance name";
      type string;
    }

    leaf device {
      tailf:info "Target managed device";
      mandatory true;
      type leafref {
        path "/ncs:devices/ncs:device/ncs:name";
      }
    }

    leaf interface-type {
      tailf:info "Interface type — supported: GigabitEthernet, TenGigE, Bundle-Ether";
      mandatory true;
      type enumeration {
        enum GigabitEthernet { tailf:info "1G Ethernet interface"; }
        enum TenGigE          { tailf:info "10G Ethernet interface"; }
        enum Bundle-Ether     { tailf:info "LAG bundle interface"; }
      }
    }

    leaf interface-id {
      tailf:info "Interface ID, e.g. 0/0/0/1 or 0/0/0/1.100";
      mandatory true;
      type string;
    }

    leaf vlan-id {
      tailf:info "VLAN / subinterface encapsulation ID (1-4094)";
      type uint16 {
        range "1..4094";
      }
    }

    leaf ip-address {
      tailf:info "Interface IPv4 address in prefix notation, e.g. 10.0.0.1/30";
      mandatory true;
      type inet:ipv4-prefix;
    }
  }
}
```

### Template variables

Template XML variables use `{/variable-name}` syntax referencing the YANG model:

```xml
<config-template xmlns="http://tail-f.com/ns/config/1.0"
                 servicepoint="my-svc-servicepoint">
  <devices xmlns="http://tail-f.com/ns/ncs">
    <device>
      <name>{/device}</name>
      <config>
        <!-- Device-specific config here, e.g. for IOS-XR: -->
        <interface xmlns="Cisco-IOS-XR-ifmgr-cfg">
          <GigabitEthernet>
            <interface-name>GigabitEthernet0/0/0/0.{/vlan-id}</interface-name>
            <active>act</active>
          </GigabitEthernet>
        </interface>
      </config>
    </device>
  </devices>
</config-template>
```

### Template with interface type conditionals

When the YANG model has an `interface-type` enumeration, use `<?if?>...<?end?>` blocks so each interface type gets its own XML payload. Lines shared across all types are emitted once, outside any conditional:

```xml
<config-template xmlns="http://tail-f.com/ns/config/1.0"
                 servicepoint="my-svc-servicepoint">
  <devices xmlns="http://tail-f.com/ns/ncs">
    <device>
      <name>{/device}</name>
      <config>
        <!-- shared config common to all interface types goes here -->
        <?if {interface-type = 'GigabitEthernet'}?>
        <interface xmlns="Cisco-IOS-XR-ifmgr-cfg">
          <GigabitEthernet>
            <interface-name>{/interface-id}</interface-name>
            <active>act</active>
            <encapsulation>
              <dot1q>
                <vlan-id xmlns="Cisco-IOS-XR-l2-eth-infra-datatypes">{/vlan-id}</vlan-id>
              </dot1q>
            </encapsulation>
          </GigabitEthernet>
        </interface>
        <?end?>
        <?if {interface-type = 'TenGigE'}?>
        <interface xmlns="Cisco-IOS-XR-ifmgr-cfg">
          <TenGigE>
            <interface-name>{/interface-id}</interface-name>
            <active>act</active>
            <encapsulation>
              <dot1q>
                <vlan-id xmlns="Cisco-IOS-XR-l2-eth-infra-datatypes">{/vlan-id}</vlan-id>
              </dot1q>
            </encapsulation>
          </TenGigE>
        </interface>
        <?end?>
        <?if {interface-type = 'Bundle-Ether'}?>
        <interface xmlns="Cisco-IOS-XR-ifmgr-cfg">
          <Bundle-Ether>
            <interface-name>{/interface-id}</interface-name>
            <active>act</active>
            <encapsulation>
              <dot1q>
                <vlan-id xmlns="Cisco-IOS-XR-l2-eth-infra-datatypes">{/vlan-id}</vlan-id>
              </dot1q>
            </encapsulation>
          </Bundle-Ether>
        </interface>
        <?end?>
      </config>
    </device>
  </devices>
</config-template>
```

> **Always generate this template from `load-native-config` output** (see [service-from-config.md](./service-from-config.md) Step 7). Never hand-author device XML — the NED's namespace and element names must come from the real NED.

### Python service callbacks

Full callback example with `vars.add()` rules:

```python
import ncs
from ncs.application import Service

class ServiceCallbacks(Service):
    @Service.create
    def cb_create(self, tctx, root, service, proplist):
        self.log.info(f'Service create: {service._path}')
        vars = ncs.template.Variables()

        # One vars.add() call per {/leaf-name} token used in the XML template.
        # Variable name (first arg) must match the token name in the template.
        vars.add('DEVICE',         service.device)
        vars.add('INTERFACE_TYPE', service.interface_type)  # GigabitEthernet | TenGigE | Bundle-Ether
        vars.add('INTERFACE_ID',   service.interface_id)
        vars.add('VLAN_ID',        service.vlan_id)
        vars.add('IP_ADDRESS',     service.ip_address)

        template = ncs.template.Template(service)
        template.apply('my-svc-template', vars)

class Main(ncs.application.Application):
    def setup(self):
        self.log.info('Main RUNNING')
        self.register_service('my-svc-servicepoint', ServiceCallbacks)

    def teardown(self):
        self.log.info('Main FINISHED')
```

**Rules:**
- Every `{/leaf-name}` token in the XML template → exactly one `vars.add('LEAF_NAME', service.leaf_name)`
- Do **not** add `vars.add()` for leaves not referenced in the template
- Variable key names (first arg) are by convention UPPER_SNAKE_CASE matching the `{/leaf-name}` token

---

## NSO CLI — Package Verification Commands

```
admin@ncs# show packages package
admin@ncs# show packages package my-svc
admin@ncs# show packages package my-svc component
admin@ncs# packages reload
admin@ncs# packages reload dry-run
admin@ncs# packages package my-svc redeploy
admin@ncs# packages package my-svc reload
```

---

## Common Errors

| Error | Cause | Fix |
|---|---|---|
| `ncs-make-package: command not found` | ncsrc not sourced | `source ~/nso-6.7/ncsrc` |
| `make: *** [all] Error 1` | JAVA_HOME not set (Java packages) | `export JAVA_HOME="/opt/homebrew/opt/openjdk@21"` |
| `package my-svc: compilation error` | YANG syntax error | Check `logs/ncs-python-vm-*.log` |
| `packages reload` result: false | Package has errors | Check `show packages package my-svc oper-status` |
| `no registration found for callpoint` | New validation point, Python not registered | Ensure `packages reload` (not redeploy) |
| `commit dry-run` output empty | Template XPath mismatch or `vars.add()` key typo | Print `service._path`; verify `{/leaf-name}` tokens match `vars.add('LEAF_NAME', ...)` keys |
| `commit dry-run` output missing interface type | Interface type not covered in `<?if?>` block | Add the missing `<?if {interface-type = 'X'}?>...<?end?>` block and rebuild |
| `KeyError: 'LEAF_NAME'` in Python log | `vars.add()` key used in template but not set | Add `vars.add('LEAF_NAME', service.leaf_name)` in `cb_create` |
| `load-native-config` returns empty XML | Device not synced or config file path wrong | Run `sync-from` on the netsim device; verify absolute path of `.cfg` file |
