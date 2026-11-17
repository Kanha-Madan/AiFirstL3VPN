---
name: af-nso-deep-backfill
description: 'Reconstruct a real, LLM-authored as-built understanding of an existing (brownfield) Cisco NSO service package and commit it to the aifirstspec/ package-memory store. Use for: deep backfill, analyze existing package, understand this package, reverse-engineer the spec, document brownfield package, upgrade a shallow backfill stub, raise package confidence, what does this package do. Reads the package YANG/templates/Python/meta, infers service intent + variant + connectivity_type/routing_protocol/topology + NEDs + instance-variable keys, then records it via `aifirst spec backfill --deep` (provenance=deep-backfilled, confidence raised off low). Complements the deterministic, structure-only `aifirst spec backfill --shallow`.'
argument-hint: "package name/id or path (e.g. 'deep backfill l3vpn' or 'understand packages/my-svc'); 'list' to pick from the store"
license: Proprietary
---

# NSO Deep Backfill (brownfield understanding)

Turn an existing NSO service package into a **real, LLM-authored as-built spec**
in the `aifirstspec/` store — the semantic counterpart to the deterministic,
structure-only `aifirst spec backfill --shallow`.

> Script: [scripts/extract_package.sh](scripts/extract_package.sh) ·
> Field mapping: [references/field-mapping.md](references/field-mapping.md)

## Why this exists

`aifirst spec backfill --shallow` (in the `aifirst` CLI) only enumerates files:
it writes a stub `aifirstspec/specs/<id>/spec.md` (metadata + file inventory) and
a registry row `provenance: backfilled, confidence: low`, **without** the
machine-readable `<!-- aifirst:as-built -->` fields block. As a result
`aifirst spec plan` treats every shallow-backfilled package as a blanket
`MODIFY`, and the orchestrator cannot tell what the package actually is.

This skill does what the binary structurally cannot: it **reads and understands**
the package (an LLM task) and reconstructs the same field vocabulary a greenfield
spec would carry — then commits it deterministically through the CLI so `plan`
computes true deltas and the confidence gate flips off `low`.

- **LLM (this skill):** read YANG/templates/Python/meta → infer intent.
- **CLI (`aifirst spec backfill --deep`):** persist the fields block + prose and
  upsert the registry row (`provenance: deep-backfilled`, `confidence: high`).

## When to invoke

- User asks to "deep backfill", "analyze/understand/document an existing
  package", or "reverse-engineer the spec" of a brownfield package.
- The orchestrator hits a `MODIFY` on a package whose stored spec is still a
  shallow stub (`confidence: low`) and needs it deepened before applying a delta.
- After adopting a brownfield repo (`discover` + `backfill --shallow`) to replace
  low-confidence stubs with real understanding, one package at a time.

**Do NOT** use this to author a *new* service (use `af-nso-spec-document` +
`af-nso-spec-orchestrator`), and do not run it as a shortcut to skip the
orchestrator's planning.

## Inputs

- `target` *(optional)*: package name, store `id`, or path. If omitted, list
  candidates and ask which one. Only ever deep-backfill **one** package per run.
- `confidence` *(optional)*: `high` (default) or `medium` — use `medium` when the
  source is ambiguous and your reconstruction required guesses.

## Workflow

Execute in order. This skill **reads** package source and **writes only** the
`aifirstspec/` store (via the CLI) — it never edits package source, never starts
NSO, and never persists secret values.

### Step 0 — Ensure the store exists and locate the package

1. `aifirst spec init` (idempotent) so the store is present.
2. Resolve `packages_root`: read `aifirstspec/config.yaml`. If absent, run
   `aifirst spec discover` first (it finds packages and persists the root).
3. Resolve the `target`:
   - Given a name/id/path → resolve to a package directory containing
     `package-meta-data.xml` (try `<packages_root>/<target>`, then `<target>`,
     then `packages/<target>`).
   - Not given → `aifirst spec view` to list registered packages (note which are
     `confidence: low` stubs) and/or `bash scripts/extract_package.sh --list`, present
     the candidates, and **ask the user to choose one**.
4. Record the resolved package **`id`** and directory. The `id` MUST be the
   **existing store id** — for a shallow stub that is `kebab(package name)` as
   shown by `aifirst spec view` (e.g. package `l3vpn` → id `l3vpn`). You will
   pass this verbatim as `--id` in Step 4 so the deep backfill **upgrades the
   stub in place** rather than creating a second row. (Greenfield ids are
   `service-variant`; a brownfield package only matches that shape when its
   directory is itself named that way.)

### Step 1 — Extract the raw structure (deterministic)

Run the extractor to dump everything you need to reason over in one pass:

```bash
bash scripts/extract_package.sh <package-dir>
```

(Invoked via `bash` so it runs even if the installed copy lost its executable
bit — no `chmod` needed. The script is shipped executable regardless.)

It reports: package metadata (name, version, `ncs-min-version`,
**`required-package`** entries → NED type/version), YANG modules + service
points + augmentations + (if `pyang` and an NSO install are present) the YANG
tree, templates + inferred target-NED prefixes, and Python callback
classes/hooks. Add `--json` for a machine-readable form. This step is pure
extraction — no interpretation yet.

### Step 2 — Understand the package (the LLM step)

Read the extractor output **and** open the actual source files the extractor
points at (the YANG model, each template, the Python `cb_create`, and any
`raw_configuration`-shaped content) and reconstruct the package's intent. Map
what you find onto the store's as-built field vocabulary — see
[references/field-mapping.md](references/field-mapping.md):

- `service` — the logical service name (from the module/servicepoint/meta).
- `variant` — the variant/subtype this package implements (often the package
  models a single variant; if the YANG encodes multiple, pick the one this
  package builds and note the rest in prose).
- `connectivity_type` — e.g. `dynamic` | `static` (inferred from routing/config).
- `routing_protocol` — e.g. `BGP` | `OSPF` | `static` | `connected`.
- `topology` — e.g. `full-mesh` | `hub-spoke` | `standalone`.
- `neds` — `type@version` pairs from `required-package` entries, else the
  extractor's **target NEDs** (template `xmlns=".../ned/<NED>"`). **If there is no
  `required-package` and the extractor reports `target NEDs: (none detected)`,
  leave `neds` empty** — the package writes into a *service model* (RFS/CDB) or is
  a pure action/library package. **Never guess NEDs from template filenames or
  vendor suffixes** (`rfs-service-fortinet.xml` ≠ a Fortinet NED).
- `instance_variables` — the operator-set input **key names**. For a **service**
  package use the extractor's *service input leaves*; for an **action/library**
  package use its *action/rpc input leaves* + template `{$VAR}`s. Ignore the
  *other/grouping* leaves. **Key names only.**

**Never record secret values.** Instance variables are captured as key names
only; if the source hard-codes a credential, flag it in prose (per the
no-hardcoded-credentials rule) but do not copy the value anywhere.

Then write a **comprehensive, structured "as-built understanding"**. This prose
is the durable human documentation of the package: the CLI writes it verbatim as
the `## As-built understanding` section of the living spec, so make it thorough —
it should let a downstream skill understand the package **without reopening the
source**. Do **not** summarise in a few sentences. Use `###` sub-headings (they
nest correctly under the `##` the CLI emits) and markdown tables, and **enumerate
exhaustively** (list all N modules/templates/components, not a representative
sample). Include every section that applies:

- **Overview** — 2–4 sentences: what the package is (connectivity service |
  shared library | action/RPC package), its role in the wider solution, and which
  package(s) depend on it.
- **YANG model** — a table of every module → its role. Call out the root
  container/groupings, and list **service points** and **augmentation targets**
  (`/path` → what augments it). If there are no service points, say so explicitly
  and explain what the package provides instead (groupings, actions, base model).
- **Templates** — a table of every template file → **target** → purpose, where
  target is the NED (when the template carries a `.../ned/` xmlns) **or** the
  service-model/CDB namespace it writes into (e.g. `http://com/.../services/...`).
  If none of the templates carry a `/ned/` namespace, state plainly that the
  package renders into a **service model, not devices** (and set `neds` empty).
- **Components** — a table of every Python/Java component → class → backing YANG
  action/servicepoint and callback hooks (`cb_create`, action points, etc.).
- **NED dependencies** — a table of each NED → what needs it, from
  `required-package` and template `.../ned/` xmlns only. If there are none, say so
  plainly ("no device NED — writes into the RFS/service model; depends on
  <packages>") instead of guessing NEDs from filenames.
- **Instance inputs** — the operator-set input **key names** (service leaves for a
  service package; action inputs + template `{$VAR}`s for an action package),
  grouped sensibly. Keep this consistent with the `instance_variables` field.
  Keys only, no values.
- **Behavior & assumptions** — notable logic, ordering, idempotence concerns, and
  any low-confidence guesses or ambiguities you had to resolve.

Omit only sections that genuinely don't apply. Keep it factual and free of
secrets. (The machine-block fields above stay concise; this prose is where the
full structural richness lives.)

### Step 3 — Confirm the reconstruction

Present the mapped fields and the prose summary to the user and ask them to
confirm or correct before committing. If they correct a field, use their value.
(When run as a sub-step of the orchestrator on an in-flight `MODIFY`, this
confirmation may be folded into the orchestrator's own flow.)

### Step 4 — Commit via the CLI

Write the prose to a temp file (keeps quoting clean, and the structured
multi-section understanding is large) and commit deterministically.
**Always pass `--id <id>`** using the id recorded in Step 0, so the existing stub
is upgraded in place (omitting `--id` derives a new `service-variant` id and
creates a duplicate row):

```bash
notes_file="$(mktemp)"
cat > "$notes_file" <<'EOF'
<your prose as-built understanding here>
EOF

aifirst spec backfill --deep \
  --id "<stub-id-from-step-0>" \
  --service "<service>" \
  --variant "<variant>" \
  --connectivity "<connectivity_type>" \
  --routing "<routing_protocol>" \
  --topology "<topology>" \
  --neds "<type@version,type@version>" \
  --instance-vars "<key1,key2,key3>" \
  --notes-file "$notes_file" \
  --confidence high

rm -f "$notes_file"
```

Omit a field you genuinely could not determine (leave it empty rather than
guess); prefer `--confidence medium` when several fields were guesses.

Exit codes (branch on these, don't parse stdout): `0` ok, `2` usage, `1` error.

### Step 5 — Verify and report

```bash
aifirst spec show <id>     # living spec now has the machine block + prose
aifirst spec plan --spec <some-input.yaml>   # if applicable: real deltas, not blanket MODIFY
```

Report: the resolved `id`, the mapped fields, the confidence recorded, and the
fact that the registry row moved `backfilled/low → deep-backfilled/<confidence>`.

## Key rules

- **One package per run**; deep understanding is per-package.
- **Reuse the stub's id.** Always commit with `--id <existing-id>` so a shallow
  stub is upgraded in place; deriving a fresh `service-variant` id would leave
  the low-confidence stub behind and add a duplicate row.
- **LLM understands, CLI persists.** All durable writes go through
  `aifirst spec backfill --deep` — never hand-edit `packages-registry.md` or the
  machine block in `spec.md` (the CLI owns their format).
- **Never persist secrets.** Instance variables are key names only; flag any
  hard-coded credential found in source, never copy its value.
- **Don't invent NEDs.** No `required-package` and `target NEDs: (none detected)`
  ⇒ the package targets a service model / is an action-library ⇒ `neds` is
  **empty**, and its dependencies are inter-package (named in prose). Inferring
  NEDs from template filenames or vendor suffixes is a bug, not a best-effort
  guess — a trailing `@` on a guessed name (`fortinet-fmg@`) is the tell.
- **Read-only on package source.** This skill never modifies YANG/templates/
  Python and never starts or stops NSO.
- **Graceful degradation.** If the installed CLI lacks `backfill --deep` (older
  version), report that deep backfill is unavailable and fall back to writing the
  understanding into the chat/PR description; do not hand-edit the store.
- **`pyang` is optional.** The YANG tree enriches understanding but is not
  required; proceed from the raw YANG when it is unavailable.
