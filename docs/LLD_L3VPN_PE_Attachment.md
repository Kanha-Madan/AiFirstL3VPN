# Low-Level Design (LLD) — L3VPN PE Attachment Service (`l3vpn-ai`)

## 1. Document Control

| Field | Value |
|---|---|
| Document | LLD — L3VPN PE Attachment Service |
| Version | 1.0 |
| Date | 2026-11-17 |
| Author | Kanhmada |
| Status | Ready for spec generation (aifirst) |
| Reference implementation | Hand-built package `l3vpn-service` in `~/Projects/NSO_Demo` (validated) |

## 2. Purpose and Scope

Automate the provisioning of one L3VPN customer attachment on an IOS-XR PE
router with a single Cisco NSO service. One service instance configures, on one
PE device:

1. A **VRF** with IPv4/IPv6 unicast address families, import/export
   route-targets and a maximum-prefix limit.
2. An **ingress QoS policy-map** (police with burst / peak-burst, set MPLS EXP)
   and an **egress QoS policy-map** (shape).
3. A **QinQ sub-interface** placed in the VRF, with IPv4/IPv6 addressing, uRPF
   and the two service-policies attached.
4. A **BGP VRF** under the provider AS with RD, label mode per-vrf, dampening
   and redistribution of connected and static routes.

Out of scope: CE configuration, PE-CE BGP neighbours, core MPLS/LDP/SR, and
any device other than the PE.

## 3. Project Metadata

| Field | Value |
|---|---|
| project_name | `l3vpn-ai` |
| version | `1.0.0` |
| description | L3VPN customer attachment on an IOS-XR PE: VRF with route-targets and maximum-prefix, ingress police / egress shape QoS, QinQ sub-interface in the VRF, and BGP VRF with RD, label mode per-vrf, dampening and redistribution. |

## 4. Development Preferences

| Field | Value |
|---|---|
| nso_version | `6.6.1` (local install, darwin arm64) |
| ned_type | `cisco-iosxr-cli` |
| ned_version | `7.74.11` (package `cisco-iosxr-cli-7.74`) |
| package_structure | `standard-blueprint` |
| code_pattern | `python` (python-and-template: Python computes derived values, XML templates render device config) |

## 5. Network Context

| Field | Value |
|---|---|
| topology_type | `Standalone` (single NSO node, no LSA) |

```
   CE (customer)                     PE (IOS-XR)                         MPLS core
 ┌────────────┐  QinQ  S-VLAN/C-VLAN  ┌───────────────────────────┐
 │            │──────────────────────►│ GigabitEthernet0/0/1.5002 │
 │            │  52.45.120.132/30     │   vrf MSHA-ML-M           │──── BGP VPNv4/VPNv6
 └────────────┘  5936:3532::/126      │ router bgp 9730 vrf ...   │     RD/RT 9730:71728651
                                      └───────────────────────────┘
```

## 6. Environment (existing — reuse, do NOT reinstall)

| Item | Value |
|---|---|
| NSO install (NCS_DIR) | `/Users/kanhmada/Projects/NSO_Demo/nso/nso661` |
| NSO runtime (ncs-run) | `/Users/kanhmada/Projects/NSO_Demo/nso/ncs-run` (NSO already running) |
| NED package | `/Users/kanhmada/Projects/NSO_Demo/nso/neds/cisco-iosxr-cli-7.74` |
| Netsim directory | `/Users/kanhmada/Projects/NSO_Demo/nso/netsim` |
| Verified NED XML capture | `/Users/kanhmada/Projects/NSO_Demo/output/pe1-captured.xml` |
| Existing package (do not touch) | `l3vpn-service` in the same ncs-run |

The new package and service must be named **`l3vpn-ai`** so they do not collide
with the existing `l3vpn-service`.

## 7. Devices

| Device | Role | Vendor | Model | OS version | Management IP | NED type | NED version | Use |
|---|---|---|---|---|---|---|---|---|
| pe0 | PE | Cisco | IOS-XR (NSO netsim) | IOS-XR (netsim, cisco-iosxr-cli-7.74) | 127.0.0.1 | cisco-iosxr-cli | 7.74.11 | **Target device for this service** |
| pe1 | PE | Cisco | IOS-XR (NSO netsim) | IOS-XR (netsim, cisco-iosxr-cli-7.74) | 127.0.0.1 | cisco-iosxr-cli | 7.74.11 | Scratch / reference device — do not deploy to it |

Both devices use the netsim lab authgroup `default` created by `ncs-setup`
(lab only — no credentials are defined in this design).

## 8. Service Design

| Field | Value |
|---|---|
| service_name | `l3vpn-ai` |
| Service variant (subtype) | `pe-attachment` |
| Variant description | Single-PE L3VPN customer attachment: VRF + QoS + QinQ sub-interface + BGP VRF |
| connectivity_type | `static` (PE-CE attachment, routes redistributed from connected/static) |
| routing_protocol | `BGP` (VRF under provider AS, redistribute connected and static) |
| topology | `full-mesh` (any-to-any L3VPN; this service provisions one PE attachment) |

## 9. Service Model (Inputs)

| Variable | YANG leaf | Type / validation | Mandatory | Default | Example |
|---|---|---|---|---|---|
| `<DEVICE>` | `device-name` | leafref → `/ncs:devices/ncs:device/ncs:name` | yes | – | `pe0` |
| `<IPV6_ENABLE>` | `ipv6-enable` | boolean; when `false` omit **all** IPv6 sections | no | `true` | `true` |
| `<BGP_AS>` | `bgp-as` | uint32 | no | `9730` | `9730` |
| `<BANDWIDTH>` | `bandwidth` | uint32, kbps, range 1..100000000 | yes | – | `1676` |
| `<VRF_NAME>` | `vrf/vrf-name` | string, length 1..32 | yes | – | `MSHA-ML-M` |
| `<RD_VALUE>` | `vrf/rd-value` | uint32; RD = `<BGP_AS>:<RD_VALUE>` | yes | – | `71728651` |
| `<RT_VALUE>` | `vrf/route-target{rt-value}` | **list** keyed by `rt-value` (uint32), `min-elements 1`; each entry has `direction` enum `import`/`export`/`both` (default `both`); RT = `<BGP_AS>:<RT_VALUE>` | yes (≥1) | direction `both` | `71728651` |
| `<MAX_PREFIX>` | `vrf/maximum-prefix/limit` | uint32 | no | `20000` | `20000` |
| `<THRESHOLD>` | `vrf/maximum-prefix/threshold` | uint8, range 1..100 | no | `80` | `80` |
| `<IN_POLICY_NAME>` | `qos/in-policy-name` | string | yes | – | `in_STANDARD_ETH_1676_By_NSO` |
| `<OUT_POLICY_NAME>` | `qos/out-policy-name` | string | yes | – | `out_STANDARD_ETH_1676_By_NSO` |
| `<MPLS_EXP>` | `qos/mpls-exp` | uint8, range 0..7 | no | `0` | `0` |
| – | `qos/burst` | uint32 bytes, optional manual override of `<BURST_BYTES>` | no | computed | – |
| – | `qos/peak-burst` | uint32 bytes, optional manual override of `<PEAK_BURST_BYTES>` | no | computed | – |
| `<INTERFACE_TYPE>` | `interface/interface-type` | enum `GigabitEthernet` | yes | – | `GigabitEthernet` |
| `<INTERFACE_ID>` | `interface/interface-id` | string, pattern `[0-9]+(/[0-9]+)*` | yes | – | `0/0/1` |
| `<SUBINTF_ID>` | `interface/subintf-id` | uint32, range 1..2147483647 | yes | – | `5002` |
| `<DESCRIPTION>` | `interface/description` | string | no | – | `MSHA-ML3-1-810095-kjajj-1676k-MSHA-ML3-1-217121-05122024` |
| `<SVLAN>` | `interface/svlan` | uint16, range 1..4094 | yes | – | `3714` |
| `<CVLAN>` | `interface/cvlan` | uint16, range 1..4094 | yes | – | `1260` |
| `<IP_ADDRESS>` | `interface/ip-address` | ipv4-address | yes | – | `52.45.120.133` |
| `<SUBNET_MASK>` | `interface/subnet-mask` | ipv4-address (dotted mask) | yes | – | `255.255.255.252` |
| `<IPV6_ADDRESS>` | `interface/ipv6-address` | ipv6 address/prefix-length; present only `when ipv6-enable = true`; **mandatory** when `ipv6-enable = true` (`must` rule) | conditional | – | `5936:3532::1/126` |

## 10. Derived Values (computed in Python — NOT user inputs)

| Variable | Formula | Example (bandwidth 1676) |
|---|---|---|
| `<POLICE_RATE_BPS>` | `bandwidth × 1000` | `1676000` |
| `<SHAPE_RATE_BPS>` | `bandwidth × 1000` | `1676000` |
| `<BURST_BYTES>` | `qos/burst` if set, else `POLICE_RATE_BPS × 1.5 / 8` (integer division: `rate × 3 // 16`) | `314250` |
| `<PEAK_BURST_BYTES>` | `qos/peak-burst` if set, else `2 × BURST_BYTES` | `628500` |
| (interface id) | `<INTERFACE_ID>` + `.` + `<SUBINTF_ID>` | `0/0/1.5002` |

## 11. Raw Configuration — variant `pe-attachment` (IOS-XR)

```
vrf <VRF_NAME>
 address-family ipv4 unicast
  import route-target
   <BGP_AS>:<RT_VALUE>
  exit
  export route-target
   <BGP_AS>:<RT_VALUE>
  exit
  maximum prefix <MAX_PREFIX> <THRESHOLD>
 exit
 address-family ipv6 unicast
  import route-target
   <BGP_AS>:<RT_VALUE>
  exit
  export route-target
   <BGP_AS>:<RT_VALUE>
  exit
  maximum prefix <MAX_PREFIX> <THRESHOLD>
 exit
exit
policy-map <IN_POLICY_NAME>
 class class-default
  police rate <POLICE_RATE_BPS> bps burst <BURST_BYTES> bytes peak-burst <PEAK_BURST_BYTES> bytes
   conform-action set mpls experimental imposition <MPLS_EXP>
   conform-action transmit
   exceed-action drop
  !
 !
 end-policy-map
!
policy-map <OUT_POLICY_NAME>
 class class-default
  shape average <SHAPE_RATE_BPS> bps
 !
 end-policy-map
!
interface <INTERFACE_TYPE><INTERFACE_ID>.<SUBINTF_ID>
 description <DESCRIPTION>
 bandwidth <BANDWIDTH>
 encapsulation dot1q <SVLAN> second-dot1q <CVLAN>
 service-policy input <IN_POLICY_NAME>
 service-policy output <OUT_POLICY_NAME>
 vrf <VRF_NAME>
 ipv4 address <IP_ADDRESS> <SUBNET_MASK>
 ipv4 verify unicast source reachable-via any allow-self-ping allow-default
 ipv4 unreachables disable
 ipv6 verify unicast source reachable-via any allow-default allow-self-ping
 ipv6 address <IPV6_ADDRESS>
 ipv6 unreachables disable
 no shutdown
exit
router bgp <BGP_AS>
 vrf <VRF_NAME>
  rd <BGP_AS>:<RD_VALUE>
  address-family ipv4 unicast
   label mode per-vrf
   bgp dampening
   redistribute connected
   redistribute static
  exit
  address-family ipv6 unicast
   label mode per-vrf
   bgp dampening
   redistribute connected
   redistribute static
  exit
 exit
exit
```

## 12. Conditional Logic

| Condition | Behaviour |
|---|---|
| `ipv6-enable = false` | Omit: VRF `address-family ipv6 unicast`; interface `ipv6 verify …`, `ipv6 address …`, `ipv6 unreachables disable`; BGP VRF `address-family ipv6 unicast`. |
| `ipv6-enable = true` and no `ipv6-address` | Reject the commit with: `interface/ipv6-address is required when ipv6-enable is true`. |
| Route-target `direction = import` | Render the RT only under `import route-target` (both AFs). |
| Route-target `direction = export` | Render the RT only under `export route-target` (both AFs). |
| Route-target `direction = both` (default) | Render under both `import` and `export`. |
| Multiple route-targets | One line per RT entry in each applicable block. |
| `qos/burst` or `qos/peak-burst` set | Use the given value instead of the computed one. |

## 13. NED Data-Model Notes (cisco-iosxr-cli-7.74, verified by capture)

Template element names must follow the NED, not the CLI text. Verified from
`output/pe1-captured.xml`:

| CLI | NED XML path / element |
|---|---|
| `vrf X` | `vrf/vrf-list{name}` |
| `import route-target 9730:N` | `address-family/ipv4/unicast/import/route-target/address-list{name}` |
| `maximum prefix 20000 80` | `maximum/prefix/limit` and **`mid-thresh`** (not `threshold`) |
| `policy-map X / class class-default` | `policy-map{name}/class/class-default/map = class-default` |
| `police rate … burst … peak-burst …` | `police-rate-unit/police/rate/{cir, cir-unit, burst, burst-units, peak-burst, peak-burst-units}` |
| `conform-action …`, `exceed-action drop` | **inside** `rate`: `rate/conform-action/{set/mpls/experimental/imposition, transmit}`, `rate/exceed-action/drop` |
| `shape average N bps` | `class-default/shape/average/{rate, rate-unit}` |
| `interface GigabitEthernet0/0/1.5002` | `interface/GigabitEthernet-subinterface/GigabitEthernet{id = 0/0/1.5002}` |
| `encapsulation dot1q S second-dot1q C` | `encapsulation/dot1q/{vlan-id, second-dot1q}` |
| `service-policy input/output X` | `service-policy/input/name`, `service-policy/output/name` |
| `ipv4 address A M` | `ipv4/address/{ip, mask}` |
| `ipv4 verify unicast source reachable-via any allow-self-ping allow-default` | `ipv4/verify/unicast/source/{reachable-via = any, allow-self-ping, allow-default}` |
| `ipv4 unreachables disable` | `ipv4/unreachables/disable` |
| `ipv6 address P/L` | `ipv6/address/prefix-list{prefix}` |
| `router bgp 9730` | `router/bgp/bgp-no-instance{id}` |
| `vrf X / rd …` | `bgp-no-instance/vrf{name}/rd` |
| `label mode per-vrf` | `address-family/ipv4/unicast/label/mode/per-vrf` |
| `bgp dampening` | `address-family/ipv4/unicast/bgp/dampening` |
| `redistribute connected` / `static` | `address-family/ipv4/unicast/redistribute/{connected, static}` |
| `no shutdown` | Not templated — the NED renders `no shutdown` for new sub-interfaces. |

## 14. Sample Service Instance (acceptance data)

| Input | Value |
|---|---|
| name | `MSHA-ML3-1-810095` |
| device-name | `pe0` |
| ipv6-enable | `true` |
| bandwidth | `1676` |
| vrf vrf-name / rd-value | `MSHA-ML-M` / `71728651` |
| vrf route-target | `71728651` (direction `both`) |
| vrf maximum-prefix limit / threshold | `20000` / `80` |
| qos in-policy-name / out-policy-name | `in_STANDARD_ETH_1676_By_NSO` / `out_STANDARD_ETH_1676_By_NSO` |
| qos mpls-exp | `0` |
| interface type / id / subintf | `GigabitEthernet` / `0/0/1` / `5002` |
| interface description | `MSHA-ML3-1-810095-kjajj-1676k-MSHA-ML3-1-217121-05122024` |
| interface svlan / cvlan | `3714` / `1260` |
| interface ip-address / subnet-mask | `52.45.120.133` / `255.255.255.252` |
| interface ipv6-address | `5936:3532::1/126` |

**Acceptance criterion:** with these inputs on `pe0`, `commit dry-run outformat
native` must render the raw configuration in section 11 with values substituted —
in particular `police rate 1676000 bps burst 314250 bytes peak-burst 628500 bytes`,
`shape average 1676000 bps`, `rd 9730:71728651`, and
`interface GigabitEthernet 0/0/1.5002`. Show the dry-run before any real commit.

## 15. Test Cases

| # | Test | Expected result |
|---|---|---|
| T1 | Create sample instance (section 14), dry-run native | Output matches section 11 with substituted values |
| T2 | Commit, then `check-sync` (service and device) | `in-sync true` / `result in-sync` |
| T3 | Change `bandwidth` to `2000`, dry-run | Only diffs: `police rate 2000000 bps burst 375000 bytes peak-burst 750000 bytes`, `shape average 2000000 bps`, interface `bandwidth 2000` |
| T4 | Create with `ipv6-enable false` (no ipv6-address) | No IPv6 lines in VRF, interface or BGP |
| T5 | `ipv6-enable true` without `ipv6-address` | Commit aborted with the `must` error message |
| T6 | No route-target | Commit aborted: at least 1 `route-target` required |
| T7 | Route-target with `direction import` only | RT rendered only under `import route-target` |
| T8 | `svlan 0` or `svlan 4095` | Rejected by range validation |
| T9 | Manual change on device (description), then `check-sync` / `re-deploy` | `in-sync false`, then restored by `re-deploy` |
| T10 | Delete service, dry-run | Removes VRF, both policy-maps, sub-interface and BGP VRF only; `router bgp 9730` remains if used elsewhere |

## 16. Service Lifecycle

- **Create / modify / delete** via NSO FASTMAP — only the create logic is implemented;
  modify sends minimal diffs and delete removes exactly what the service created.
- Operational checks: `check-sync`, `get-modifications`, `re-deploy`.

## 17. Security

- No credentials, keys or tokens in the package, templates, spec or this document.
- Device access uses the NSO authgroup `default` (netsim lab only). Production
  devices must use a dedicated authgroup with credentials entered interactively
  and stored encrypted in NSO.

## 18. Assumptions and Open Items

| # | Item | Status |
|---|---|---|
| A1 | Burst / peak-burst formula (`rate × 1.5 / 8`, `2 × burst`) matches the instructor's sample values | Assumed; manual override leaves provided |
| A2 | Only `GigabitEthernet` sub-interfaces in v1.0 | Extend enum (e.g. `TenGigE`, `Bundle-Ether`) in a later version |
| A3 | Provider BGP AS `9730` is fixed per network | Modelled as leaf with default `9730` |
| A4 | Same RT value used for import and export in the sample | Supported via `direction both`; separate values supported via the list |
