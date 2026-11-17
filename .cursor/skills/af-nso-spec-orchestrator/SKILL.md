---
name: af-nso-spec-orchestrator
description: 'Cisco NSO spec-driven, end-to-end service build orchestrator. Use for: build from spec, build services from spec file, here is a spec file, spec-driven service build, L3VPN spec YAML, generate packages from spec, provision environment from spec, orchestrate NSO from spec. Ingests a service spec YAML, reconciles the local NSO environment (NSO version, NEDs, netsim devices) idempotently, then builds and validates one service package per service variant by delegating to the af-nso-local-install, af-nso-install-ned, af-nso-manage-devices, and af-nso-manage-package skills. Never re-implements delegated skill logic.'
argument-hint: 'path to a service spec YAML provided by the user'
license: Proprietary
---

# NSO Spec-Driven Service Build Orchestrator

A **conductor** skill: it ingests a service spec YAML, reconciles the local NSO
environment against it, then builds and validates one service package per
service variant. It **delegates** every action to an existing skill and **never
re-implements** their logic.

| Concern | Delegated to |
|---|---|
| Install NSO (missing version) | [af-nso-local-install](../af-nso-local-install/SKILL.md) |
| Download + install NEDs | [af-nso-install-ned](../af-nso-install-ned/SKILL.md) |
| Create/load/sync netsim devices | [af-nso-manage-devices](../af-nso-manage-devices/SKILL.md) |
| Build + validate service package per variant | [af-nso-manage-package](../af-nso-manage-package/SKILL.md) |

> Reference docs:
> [references/spec-driven-flow.md](./references/spec-driven-flow.md) ·
> [references/spec-schema.md](./references/spec-schema.md) ·
> [references/orchestration-flow.md](./references/orchestration-flow.md) ·
> [references/subagent-fanout.md](./references/subagent-fanout.md)

---

## Inputs

- **spec-path** *(required)*: path to a service spec YAML provided by the user. If omitted, ask the user for it. The spec must already be **human-reviewed and confirmed** (the review gate runs in `af-nso-spec-document` before this skill is invoked) — if you are not sure it was approved, ask the user to confirm before building.
- **instance variable values** *(collected during Step 3)*: concrete values for
  the `<...>` placeholders declared in each variant's `instance_variables`,
  elicited from the user before any package is built.

### v1 guardrails (supported subset)

This version supports **`Standalone`** topology and the **`python`** code
pattern only. LSA topology and Java callbacks cause an immediate halt-and-report
(see Step 2) — no environment or package changes are made.

---

## Workflow

Execute the steps **in order**. Do not skip Step 1, Step 2, or Step 3. Never start
NSO yourself except through the explicit `af-nso-local-install` delegation in Step 4.

### Execution model — run at the top level, fan out per service

This skill MUST be run by the **top-level agent** (the one that has the
`runSubagent` tool). A subagent cannot spawn further subagents, so if the
orchestrator is nested inside a subagent it **cannot** parallelize — in that case
report that fan-out is unavailable and fall back to authoring services
sequentially in-place (Step 5, fallback mode).

Large specs (many `service_name`s / variants) are built in three phases:

| Phase | Steps | Concurrency |
|---|---|---|
| **A — Serial setup (once)** | 0 consult package memory · 1 parse · 2 guardrails · 3 elicit · 4 reconcile | serial |
| **B — Parallel authoring** | 5 fan out one subagent per `service_name` | parallel (bounded) |
| **C — Serial reintegration** | 6 reload + per-variant validate | serial |
| **D — Publish** | 7 branch/commit/push/PR · archive change memory · 8 report | serial |

Everything that touches the shared NSO runtime (install, `packages reload`, CDB
commit, device sync, service instantiation, `load-native-config`) stays in the
serial phases, as does publishing (it touches the shared git remote). Only
file-only authoring runs in parallel.

---

### Step 0 — Consult package memory (cross-session)

Before parsing, orient against what was built before via the **aifirst CLI**
package-memory store (`aifirstspec/`). This is what lets a fresh session know
whether each service variant is **new** or a **modification** of an existing
package. All of this is deterministic CLI work — the skill only branches on the
results (JSON + exit codes: `0` ok, `2` usage, `3` cancelled, `5` collision).

**0a — Ensure the store exists** (idempotent):

```bash
aifirst spec init
```

**0b — Adopt a brownfield repo (first run only).** If the store is newly created
or its registry is empty while NSO packages already exist in the workspace, seed
current state so the delta is correct:

```bash
aifirst spec discover           # find package-meta-data.xml, detect packages-root
aifirst spec backfill --shallow # stub as-built specs (provenance: backfilled)
```

`--shallow` seeds structure-only stubs (`confidence: low`). To promote a stub to
a real, LLM-authored as-built understanding — either eagerly after adoption or
lazily on a `MODIFY` (Step 5) — use the
[af-nso-deep-backfill](../af-nso-deep-backfill/SKILL.md) skill.

**0c — Decide new vs modify** for every variant in the incoming spec:

```bash
aifirst spec plan --spec <spec-path>
```

Parse the JSON array; each entry is `{ id, service, variant, decision }` where
`decision` ∈ `NEW | MODIFY | NOOP`. Record the **decision map** keyed by package
`id` — it drives package naming (Phase A end), authoring (Step 5), and change
recording (Step 7). On exit code `5` (identity collision) **halt and report**; if
every variant is `NOOP`, report that the build is already up to date and stop
before touching the environment.

**0c′ — Reconcile a `NEW` verdict against in-flight work.** `plan` decides
`NEW`/`MODIFY` against the **durable** registry, which is only written at
**archive**. So a package whose build is still **open** (unarchived) reads as
`NEW` even though it already exists on disk and under an active change. Before
treating any `NEW` as a fresh scaffold, run `aifirst spec view` and check
**Active changes**: if a change already covers this spec's service, you are
**resuming an in-flight build** — refresh it with `aifirst spec change new --spec
<spec-path> --force` and edit the existing packages **in place**; do not
re-scaffold or duplicate. (Once the CLI's `plan` output carries an `active_change`
/ `on_disk` field, branch on that directly instead of a separate `view` call.)

**0d — Open one change record for this build** (covering every `NEW`/`MODIFY`
variant from 0c) so the work is captured:

```bash
aifirst spec change new --spec <spec-path>   # once per build; covers all variants
```

This stamps a single dated change directory (`<date>-<service-slug>`) and freezes
an immutable `spec-snapshot.yaml` with one entry per package (secret values are
never written — instance-variable **keys** only). The change `<name>` defaults to
the kebab-cased service name(s); pass `--name <slug>` to override. A change name
allows only one active instance — if the spec was re-edited after raising it,
re-raise with `--force`. **Capture the resulting change name** for Step 7.

> **Graceful degradation.** If the installed CLI lacks `aifirst spec` (older
> version), read `aifirstspec/packages-registry.md` directly to decide new vs
> modify, warn that memory features are limited, and continue. Never block a
> build solely because package memory is unavailable.

---

### Step 1 — Parse the spec

Read the spec YAML at `spec-path` and extract the normalized build inputs
(full field reference: [references/spec-schema.md](./references/spec-schema.md)):

- `development_preferences.nso_version` → required NSO version
- `development_preferences.ned_type` → comma-separated NED slugs (e.g.
  `cisco-iosxr,cisco-nx`)
- `development_preferences.code_pattern` → `python` | `java`
- `network_context.topology_type` → `Standalone` | `LSA`
- `devices[]` → role / vendor / model / os_version inventory
- For each `services[].service_variants[]`: `subtype`, `deployment_model`, and
  every `supported_devices[]` entry's `ned.type`, `ned.version`,
  `instance_variables` (if present), and `raw_configuration`

**Build the required-NED set** by collecting every distinct `(type, version)`
pair found across `development_preferences.ned_type` and each variant's
per-device `ned` block.

**Present a summary** before any action:

```
Spec: <spec-path>
NSO version required: <x.y>
NEDs required: <type-version>, <type-version>, ...
Topology: <Standalone|LSA>   Code pattern: <python|java>
Device roles: <role/model>, ...
Service variants to build (N): <subtype>, <subtype>, ...
Instance variables to collect: <count> (<shared-count> shared)
```

**Halt on a missing required field.** If `nso_version`, a required `ned` block,
or a variant's `raw_configuration` is absent, report the exact missing field and
its spec path and **stop** — do not start reconciliation.

---

### Step 2 — Guardrails (halt before any change)

Immediately after parsing, before touching the environment:

- If `network_context.topology_type` is **`LSA`** → **halt and report**: only
  `Standalone` topology is supported in v1.
- If `development_preferences.code_pattern` is **`java`** → **halt and report**:
  only the `python` code pattern is supported in v1.

Make no environment or package changes when halting.

---

### Step 3 — Collect instance variable values (elicitation)

Variables in each variant's `raw_configuration` are written as angle-bracket
placeholders (e.g. `<vrf-name>`) and declared in that device's
`instance_variables` map. Concrete values are required **before** building,
because the `af-nso-manage-package` service-from-config workflow pushes a *real*
native config through the NED (`load-native-config`) and instantiates a test
service — angle-bracket placeholders are not valid device config. Collect values
first, elicitation-first (like MCP), before any package is created.

> If a variant has no `instance_variables` and its `raw_configuration` contains no
> `<...>` tokens, skip this step for that variant.

**3a — Aggregate the variable set.** Collect every `instance_variables` entry
across all variants. For each, record: the key (e.g. `vrf_name`), its placeholder
token exactly as it appears in `raw_configuration` (e.g. `<vrf-name>`), and its
description comment.

- **Shared variables** — entries whose comment says `shared across variants`:
  collect **one** value and reuse it for every variant that uses it.
- **Per-variant / per-instance variables** — all others: collect a value **per
  variant** that declares them.
- Preserve source key names verbatim, including typos (e.g.
  `intergace_type_and_id` → token `<intergace-type-and-id>` in the first
  variant). Map each key to the exact token in `raw_configuration`, not a
  normalized name.

**3b — Prompt the user (single consolidated elicitation).** Present the variables
grouped as *shared* then *per-variant*, each with its description, and ask for
values in one pass:

```
Shared values (used by all variants):
  vrf_name    — VRF name for the service instance:        ____
  as_number   — BGP AS number:                            ____
  rt_value    — Route-target value (import and export):   ____
  ...
Variant "L3VPN Full Mesh Connected":
  interface_ip — PE-CE interface IPv4 address:            ____
  neighbor_ip  — BGP CE neighbor IP address:              ____
  ...
```

**3c — Validate and handle secrets.**
- Every `<...>` token used in a variant's `raw_configuration` MUST receive a
  non-empty value; halt and report any unfilled token before building.
- **Credential variables** (e.g. `password` — "Encrypted BGP neighbor password")
  are secrets: never hard-code them into the spec, the package, or any file, and
  never echo them back. Take the value at prompt time only, use it solely to
  render the concrete config for `load-native-config`/test, and do not persist
  it. If no real value is available, use a clearly-marked throwaway value for the
  netsim dry-run and flag it in the report.

**3d — Render the concrete config.** For each variant, substitute the collected
values into its `raw_configuration` (token → value) to produce the concrete
native CLI config handed to Step 5. Keep the key → token → value mapping so the
service-from-config workflow can turn each token into the matching YANG service
leaf (shared → service-level leaf; per-instance → per-endpoint leaf).

---

### Step 4 — Reconcile the environment (idempotent, check-then-act)

For each requirement, **check current state first** and delegate **only on a
gap**. Never re-install or re-create something that already satisfies the spec.
Full detail: [references/orchestration-flow.md](./references/orchestration-flow.md).

**4a — NSO version**

```bash
ncs --version   # compare against required nso_version
```

- Match → record satisfied; do **not** invoke `af-nso-local-install`.
- Missing / mismatch → delegate to **af-nso-local-install** to install the required
  version.

**4b — NEDs** (for each required `(type, version)`):

```bash
ncs_cli -Cu admin -c 'show packages package <ned> | include VERSION' 2>/dev/null
```

- Installed at the required version → mark satisfied.
- Missing → delegate to **af-nso-install-ned** (it resolves + auto-downloads +
  installs). Repeat per distinct NED slug (handles multi-NED comma lists).

**4c — Netsim devices** (for each spec `device` role/model):

```bash
ncs_cli -Cu admin -c 'show devices list' 2>/dev/null
```

- A matching, synced netsim device exists → mark satisfied.
- Missing → delegate to **af-nso-manage-devices** to create, load, fetch SSH host
  keys, and sync-from the device.

> **NSO must be running** for 4b/4c CLI checks. If NSO is stopped and version was
> already satisfied in 4a, halt and report — do not auto-start NSO.

**End of Phase A.** Before fanning out, take the **package `id` per service
variant** from the Step 0 decision map (`aifirst spec plan`, e.g.
`l3vpn-full-mesh`) as the unique package name; the ids and their `NEW`/`MODIFY`
decisions are passed to the authoring subagents and reused unchanged in
reintegration and change recording.

---

### Step 5 — Author packages (Phase B — parallel fan-out)

Spawn **one subagent per `service_name`** (via `runSubagent`, using the
`NSO Agent`) to author that service's variants **in parallel**. Authoring is pure
file work and safe to parallelize. Full contract:
[references/subagent-fanout.md](./references/subagent-fanout.md).

**Each subagent does authoring only:**
- Scaffold the package(s), write YANG / template / Python, run the `make` build,
  for every variant of its assigned service.
- It MUST NOT run any NSO-global operation — no `packages reload`, no CDB commit,
  no device sync, no service instantiation, no `load-native-config`.

**Subagent brief (input)** — pass exactly:
- the `service_name` and its list of variants (`subtype`s),
- the **concrete** rendered config per variant (from Step 3),
- the key → token → value variable mapping,
- the assigned target package `id`(s) and each variant's `NEW`/`MODIFY` decision
  from Step 0.

**New vs modify (per variant):**
- `NEW` → scaffold a fresh package under the `id`.
- `MODIFY` → edit the **existing** package in place; do not scaffold a duplicate.
  If that package's stored spec is still a shallow backfill stub
  (`confidence: low`), first **deep-backfill** it via the
  [af-nso-deep-backfill](../af-nso-deep-backfill/SKILL.md) skill: read its YANG /
  templates / Python to reconstruct the current variants and intent, commit the
  understanding with `aifirst spec backfill --deep` (flips the row to
  `deep-backfilled`/higher confidence and writes a real as-built machine block),
  then apply only the delta.

**Subagent result (output)** — expect back a structured summary:
- packages authored, per-variant authoring status, and any errors (with log
  pointers). The subagent returns files, never NSO state.

**Concurrency + isolation:**
- Bound concurrency to a small cap (default **3**) rather than spawning an
  unbounded number of subagents.
- Isolate failures: if one service's subagent fails, record it and continue the
  others.

> **Fallback (no `runSubagent`):** if fan-out is unavailable, author each
> service's variants **sequentially in-place** with the same authoring-only
> steps, then proceed to Step 6.

---

### Step 6 — Reintegrate + validate (Phase C — serial)

Performed **only by the top-level agent**, one step at a time against the single
NSO runtime:

1. Run a **single** `packages reload` after all authoring completes.
2. For **each** variant (one at a time — never concurrent): **dry-run → commit →
   verify** against the matching netsim device.
   - An **empty or incorrect dry-run** is a validation failure for that variant.
3. If a variant needs `load-native-config` / live-NED template generation, do it
   **here** (serial, top level) — not inside an authoring subagent.
4. On failure, record the variant, package name, and log pointer
   (`~/nso-run-*/logs/ncs-python-vm-<pkg>.log`, `ncserr.log`) and **continue**.

---

### Step 7 — Publish (Phase D — serial, top level)

After validation, publish the build to git by **delegating** to
[af-nso-git-pr](../af-nso-git-pr/SKILL.md). This runs **only at the top level and
serially** — never inside an authoring subagent (it touches the shared remote).

**Gate — all-or-nothing.** Publish **only if every variant passed** Step 6
validation. If **any** variant failed, **skip Phase D entirely**: create no
branch, no commit, no PR; leave the working tree and `main` untouched and proceed
to the report noting the failures.

When all variants passed, delegate to `af-nso-git-pr` with:
- the primary `service_name` (for the branch name),
- the list of build-produced `packages/<name>/` paths (the commit allow-list),
- the per-variant PASS result.

The delegated skill creates `feature/<service>-<yyyymmdd>` (one branch per spec
build), commits only the allow-listed package paths, then requires **human
confirmation at push and at PR** before pushing and opening a PR to `main`.
Capture the returned **branch name** and **PR URL** for the report.

**Record the outcome in package memory.** Once the PR is raised (or the build is
green even if push/PR was declined), close the Step 0 change **for this build** so
the living as-built specs and registry reflect the new state:

```bash
aifirst spec change archive <change-name> --pr <pr-url> --status deployed  # once per build
```

Run once for the build's change (the `<change-name>` captured in Step 0d). The
single call updates every covered package's living
`aifirstspec/specs/<id>/spec.md` and its `packages-registry.md` row (status + PR
link) and moves the change under `changes/archive/`. If Phase D was skipped due to
validation failures, leave the change open (do not archive) so the next run can
retry. Degrade gracefully if the CLI lacks `aifirst spec`.

---

### Step 8 — Aggregated report

Merge the authoring subagents' results with the serialized validation outcomes
into one summary:

```
## Spec build report — <spec-path>

Environment:
  NSO <x.y>            : installed | already present
  NED <type-version>   : installed | already present
  netsim <role/model>  : created  | already present

Instance variables: <count> collected (<shared-count> shared)
  [!] <var> — secret used as throwaway (no real value provided)   # if any

Authoring (per service, parallel):
  [OK]   <service_name>  → N package(s) authored
  [FAIL] <service_name>  → authoring error (see <log path>)

Validation (serial; P passed / F failed of N variants):
  [PASS] <subtype>  → package <pkg-name>
  [FAIL] <subtype>  → package <pkg-name>  (see <log path>)

Publish (Phase D; only when all variants passed):
  branch : feature/<service>-<yyyymmdd>
  PR     : <pr-url>            # or "skipped — validation failures"
                              # or "branch committed, push/PR declined"

Package memory (aifirstspec/):
  [NEW]    <pkg-id>  → recorded as-built  (change <date>-<pkg-id> archived, PR <pr-url>)
  [MODIFY] <pkg-id>  → updated (deep-backfilled from source)  # if any
  [NOOP]   <pkg-id>  → already up to date                     # if any
  # variants that failed validation: change left open for retry
```

---

## Key rules

- **Delegate, never fork.** Every environment or package action calls an existing
  skill's documented procedure/script. Do not embed a reimplementation.
- **Package memory is deterministic.** New-vs-modify comes from `aifirst spec
  plan` (Step 0), not guesswork; record every build with `aifirst spec change
  new`/`archive`. If `aifirst spec` is unavailable, read
  `aifirstspec/packages-registry.md` and continue — never block a build on memory.
- **Top level only.** Run where `runSubagent` exists; fan out one subagent per
  `service_name`; fall back to sequential authoring if nested in a subagent.
- **Parallelize authoring only; serialize NSO.** `packages reload`, commit,
  verify, `load-native-config`, and publishing (Phase D) are serial top-level
  steps — never run inside authoring subagents or concurrently.
- **Publish only green builds, with a human gate.** Delegate Phase D to
  `af-nso-git-pr` only when every variant passed; it creates one
  `feature/<service>-<yyyymmdd>` branch, commits only `packages/` paths, and
  requires human confirmation at push and PR. On any validation failure, skip
  publishing entirely.
- **Elicitation-first.** Collect all `instance_variables` values (Step 3) before
  creating any package — placeholders are not valid device config.
- **Never persist secrets.** Credential variables (e.g. `password`) are taken at
  prompt time only, never written to the spec, package, or any file, never echoed.
- **Idempotent.** Re-running against the same spec on a satisfied environment
  performs no installs/creates and rebuilds only what changed.
- **Halt early on unsupported input** (LSA, Java, missing fields, unfilled
  variable tokens) — no partial provisioning.
- **Never auto-start NSO** except via the `af-nso-local-install` delegation.
- **Per-variant isolation** — record and continue on failure; report at the end.
