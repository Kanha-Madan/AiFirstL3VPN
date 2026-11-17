# Field mapping — NSO package artifacts → aifirstspec store fields

How to translate what you read in an existing package into the store's as-built
field vocabulary (the same fields a greenfield spec carries, so `aifirst spec
plan` can diff a desired spec against the recorded state). Full schema:
[../../af-nso-spec-orchestrator/references/spec-schema.md](../../af-nso-spec-orchestrator/references/spec-schema.md).

The `aifirst spec backfill --deep` command records exactly these fields:

| Store field (`--flag`) | Reconstruct from | Notes |
|---|---|---|
| `service` (`--service`) | YANG module name / `servicepoint` name / `package-meta-data.xml` `<name>` / prose in comments | The logical service, e.g. `L3VPN`. |
| `variant` (`--variant`) | Package name suffix, a `subtype`-like leaf, or the specific config shape the templates render | A package usually implements one variant; if the YANG models several, pick the one this package builds and describe the rest in prose. |
| `connectivity_type` (`--connectivity`) | Routing + addressing in templates/config | Typically `dynamic` (a routing protocol peers) vs `static`/`connected`. |
| `routing_protocol` (`--routing`) | `router bgp` / `router ospf` / `ip route` in templates or `raw_configuration` | e.g. `BGP`, `OSPF`, `static`, `connected`. |
| `topology` (`--topology`) | Route-target import/export patterns, hub/spoke leaves, mesh wiring | e.g. `full-mesh`, `hub-spoke`, `standalone`. |
| `neds` (`--neds`) | `package-meta-data.xml` `<required-package>` names (authoritative — carry version); else the extractor's **target NEDs**, parsed from template device-config `xmlns=".../ned/<NED>"` | Record as `type@version`, e.g. `cisco-iosxr@7.45`. Strip the `-cli`/`-nc` suffix and trailing build noise when the required-package name embeds it, but keep the version. **If there is no `<required-package>` AND the extractor reports no `.../ned/` xmlns, leave `neds` empty** — the package targets a *service model* / CDB (its templates carry only service namespaces like `http://com/.../services/...` or `http://tail-f.com/ns/config`) or is a pure action/library package. **Never infer NEDs from template filenames or vendor suffixes** — `rfs-service-fortinet.xml` does NOT imply a Fortinet NED. |
| `instance_variables` (`--instance-vars`) | The extractor's **service input leaves** for a service package; its **action/rpc input leaves** + template `{$VAR}`s for an action/library package | **Key names only.** These are the parameters an operator sets per instance. Ignore the extractor's *other/grouping* leaves (reference-data, not inputs). Never record values. |

## NED name → `type@version` examples

| `<required-package>` name | Record as |
|---|---|
| `cisco-iosxr-cli-7.45` | `cisco-iosxr@7.45` |
| `cisco-nx-cli-5.23` | `cisco-nx@5.23` |
| `cisco-ios-cli-6.77` | `cisco-ios@6.77` |
| `juniper-junos-nc-4.14` | `juniper-junos@4.14` |

When a NED is **genuinely present** but its version is unknown (a real
`.../ned/<type>` xmlns without a version, or a bare import prefix), record the
type with an empty version (`cisco-iosxr@`) and note the missing version in prose
/ use `--confidence medium`. Do **not** emit a `type@` entry for a NED you only
*suspect*: if the extractor found no `/ned/` xmlns and there is no
`<required-package>`, leave `neds` empty rather than guessing (a trailing `@` on a
guessed name, like `fortinet-fmg@`, is the tell-tale sign of this bug).

## Service-model vs device-NED packages

Not every package configures a device. A package whose templates carry only
service/CDB namespaces (e.g. `http://com/.../services/...`,
`http://tail-f.com/ns/config`) and **no `.../ned/`** xmlns writes into another
package's *service model* (an RFS/reconciliation/orchestration layer) — it has
**no direct NED dependency** (`neds` empty). Its real dependencies are
*inter-package* (the packages that own those service namespaces + `eps-common`);
name them in prose, not in `neds`. Trust the extractor here: `target NEDs: (none
detected)` means none — do not backfill NEDs from filenames.

## Instance variables — keys only, never values

The service's input leaves are the instance variables. Capture the **leaf
names** (normalize to the source's own key style; the store treats them as
opaque strings). Example YANG:

```
list l3vpn {
  key name;
  leaf name        { type string; }
  leaf vrf-name    { type string; }
  leaf as-number   { type uint32; }
  leaf password    { type tailf:aes-cfb-128-encrypted-string; }
}
```

→ `--instance-vars "name,vrf_name,as_number,password"` (record `password` as a
**key only**). If any template or Python hard-codes a real credential value,
flag it per the no-hardcoded-credentials rule — do **not** copy the value into
notes, the store, or anywhere.

## Prose "as-built understanding" (`--notes-file`)

A few factual sentences that survive alongside the machine block:
- what the service provisions and onto which device role(s)/NED(s);
- its key inputs (the instance variables) and any defaults;
- how many variants the YANG models and which one this package builds;
- explicit callouts of anything guessed (drives `--confidence medium`) or any
  hard-coded secret found (flagged, never quoted).

Keep it free of secret values.
