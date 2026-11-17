---
name: af-qa-req-extractor
description: 'Planner procedure for deriving stable requirement IDs from the selected LLD YAML under aifirstspec/inputs/. Use for generate requirements, stable REQ IDs, traceability, semantic drift. The Planner performs it directly; no standalone Python helper.'
argument-hint: 'optional path to an LLD YAML under aifirstspec/inputs/; auto-selects the sole eligible YAML when omitted'
---

# af-qa-req-extractor — Deterministic REQ Extraction

Turns the selected LLD YAML under `aifirstspec/inputs/` into a stable
**`<spec-id>.requirements.yaml`** and **`<spec-id>.requirements.lock`**, where
`<spec-id>` is the selected source filename without `.yaml` (for example,
`l3vpn.yaml` → `l3vpn`). The Planner follows the canonicalization, ordering,
and lock rules below directly; this workflow has no standalone Python helper.

> REQ IDs are derived from LLD content using the pinned `af-qa-req-v1`
> canonicalization and ordering contract below. Identical LLD bytes produce
> identical signatures and REQ IDs on every system. Never derive IDs from an
> LLM-authored title, machine state, or filename label.

---

## When to use

- **Before Gate 1** whenever the selected LLD lacks a `requirements:` block
- User asks: "generate requirements from LLD", "extract requirements",
  "produce a requirements list", "seed the RTM"
- Coverage-gate flags: "no REQ list found" or "requirements.lock missing"

**Do not use** when:

- The LLD already has an explicit `requirements:` list — Planner reads it verbatim

**No shortcut:** an existing lock with a matching `lld_sha256` never lets a run skip extraction. Every
Planner and Builder run recomputes all requirements from the LLD and compares them to the catalog and
lock (see Mandatory verification below).

---

## Precedence (Planner reads this order)

1. **LLD `requirements:` block present** → preserve its explicit unique IDs;
   if IDs are absent, assign them with `af-qa-req-v1`.
2. **Generated catalog and lock both exist** → run the Mandatory verification
   below on every run. Consume the catalog IDs verbatim only after it passes.
   Do not reassign IDs.
3. **Only one generated artifact exists** → recompute signatures from the LLD,
   preserve matching IDs from the existing artifact, and reconstruct the
   missing artifact. Halt on unmappable semantic drift or removal.
4. **Neither generated artifact exists** → extract with `af-qa-req-v1`, write
   both artifacts, and validate them before proceeding.

To select the source, enumerate direct children of `aifirstspec/inputs/` ending
in `.yaml` whose filename stem contains no `.`; sidecars are named
`<spec-id>.<kind>.yaml` (for example `.requirements.yaml`) and are never sources.
If exactly one remains, select it automatically. If none or multiple remain,
ask for the source file path; do not ask for a track name.

---

## Inputs

| Input | Path | Role |
|-------|------|------|
| LLD YAML | User path, or sole eligible `aifirstspec/inputs/*.yaml` | Source of truth |
| REQ catalog (optional) | `aifirstspec/inputs/<spec-id>.requirements.yaml` | Carries REQ IDs and canonical requirement records |
| REQ lock (optional) | `aifirstspec/inputs/<spec-id>.requirements.lock` | Maps canonical signatures to persistent REQ IDs |

---

## Outputs

| Artifact | Path | Purpose |
|----------|------|---------|
| Human-readable REQ catalog | `aifirstspec/inputs/<spec-id>.requirements.yaml` | Portable stable IDs and requirement data consumed by Planner and Builder |
| ID lock | `aifirstspec/inputs/<spec-id>.requirements.lock` | Enforces stable IDs across runs |

Both files are **deterministic** — include `algorithm: af-qa-req-v1`, no
timestamps, sorted keys, and canonical YAML formatting. Keep them versioned
together as the portable ID map. A legacy file without `algorithm` may be
treated as v1 only after its signatures and existing ID order validate; add the
metadata without changing IDs.

---

## Extraction categories (fixed, five)

| # | Category | Extracted from | Priority |
|---|----------|----------------|----------|
| 1 | **structural** | One REQ per distinct top-level stanza of each variant's `raw_configuration` (for example `vrf`, `interface`, `router bgp`). Nested lines such as `neighbor`, `redistribute`, `mtu`, or `encapsulation dot1q N` belong to their stanza and are never separate REQs; literal values stay in the signature | P0 |
| 2 | **behavioral** | `deployment_model.{connectivity_type, routing_protocol, topology}` — one REQ per unique (key, value) tuple | P0 |
| 3 | **input-contract** | Every leaf in `instance_variables` — one REQ per leaf, folded across variants that share the leaf | P0 (mandatory) / P2 (optional) |
| 4 | **lifecycle** | Always emitted, fixed 5-tuple | P1 |
| 5 | **non-functional (`nfr`)** | Pattern-matched: `password encrypted` in raw_configuration → security; MTU present → interface behavior; more than one distinct NED type or vendor across variants → matrix | P0 (security) / P1 (other) |

**`applies_to` rules:** structural, behavioral, and input-contract REQs apply to the variants that
contain that signature. Lifecycle REQs apply to every variant of the service. An `nfr` REQ applies only
to the variants that individually match its pattern (`password encrypted` in that variant's
`raw_configuration`; `mtu` among that variant's `instance_variables`), never to all variants.

**Fold rule:** identical canonicalized signature (`signature_sha1`) across variants
collapses into one REQ with `applies_to: [variant1, variant2, …]`.

## Cross-system ID contract: `af-qa-req-v1`

Every system must apply this exact algorithm; do not substitute LLM ordering,
locale-aware sorting, filesystem order, or platform-default encoding:

1. Parse the selected LLD as YAML data. Calculate `lld_sha256` over its exact
   UTF-8 file bytes; this detects any source-file change.
2. Extract candidates only from the five fixed categories below. Do not infer
   candidates from prose, comments, timestamps, or fields outside those rules.
3. Build each category's canonical signature string exactly as specified below
   and calculate lowercase hexadecimal SHA-1 over its UTF-8 bytes. This
   `signature_sha1` is an identity key, not a security control; retain it to
   preserve existing locked IDs.
4. Fold equal signatures across variants. Sort `applies_to` values by Unicode
   code-point order.
5. Sort unique candidates by `(category_rank, signature_sha1)` using ascending
   bytewise order of the lowercase ASCII hex signature. Assign sequential IDs
   from 001 as `REQ-<SERVICE>-<NNN>`, where `<SERVICE>` is the uppercase ASCII
   form of `services[].service_name`. The input filename and project name do
   not affect the ID. Serialize requirements by ascending numeric ID.
6. Identical LLD bytes processed with `af-qa-req-v1` must produce identical
   IDs, signatures, priorities, and variant mappings on every system.

Keep the catalog and lock versioned together as the portable ID map. If both
are absent, the algorithm above independently reproduces the same IDs. If
either exists, preserve matching IDs after signature validation; never
renumber a requirement because another system regenerated the catalog. A source
hash mismatch caused by non-semantic YAML edits requires re-extraction, but
unchanged requirement signatures retain their IDs.

---

## Canonicalization rules (per category)

**Compute every hash with a command, never by estimation.** An LLM cannot compute SHA-1 reliably, and
the order of the signatures decides every REQ number. Run one terminal command that prints all
signatures, for example
`python3 -c 'import hashlib,sys;[print(hashlib.sha1(s.encode()).hexdigest()) for s in sys.argv[1:]]' "<canonical 1>" "<canonical 2>"`
(or `printf '%s' "<canonical>" | shasum -a 1` per string). If no terminal is available, halt instead of
approximating. This is a one-off command, not a helper script. Keep each line's original leading
spaces, join lines with a single `\n` and no trailing newline, and use leaf names exactly as written in
the LLD, including misspellings such as `intergace_type_and_id`.

**Structural:**

- Split `raw_configuration` on newlines
- Strip trailing whitespace, drop blank lines and standalone `!`
- Group by indent: indent-0 lines start a stanza; children belong until next indent-0
- Replace every `<placeholder>` token with literal `<PARAM>`
- Preserve literal values verbatim (`dot1q 13` and `dot1q 57` remain distinct → distinct REQs)
- SHA-1 the UTF-8 bytes of the LF-joined canonical stanza text

**Behavioral:** signature = SHA-1 of UTF-8 `key=value`.

**Input-contract:** signature = SHA-1 of UTF-8 `input:<leaf_name>` — same leaf across variants folds

**Optional-leaf rule (data only; never read YAML comments or leaf names):** within one variant, a leaf is
optional when its placeholder (`<leaf-name>`, underscores written as hyphens) is the only content on a
`raw_configuration` line after trimming whitespace. Any other leaf, including one that never appears in
`raw_configuration`, is mandatory. A folded leaf is optional only if it is optional in every variant that
declares it. Record the result per variant as `optional: true|false` in the evidence. It sets the priority
(P2 optional, P0 mandatory) and title template, not the signature or ID.

**Lifecycle:** fixed signatures: SHA-1 of UTF-8 `lifecycle:create`, `lifecycle:modify`, `lifecycle:delete`, `lifecycle:dry-run-consistency`, `lifecycle:rollback-on-failure`.

**NFR:** signature = SHA-1 of UTF-8 `nfr:<pattern_key>`.

---

## Deterministic title templates (no LLM authoring)

| Category | Title template |
|----------|----------------|
| structural | `"<head_word> block: <sorted child keys joined by ' + '>"` — e.g. `"vrf block: description + import route-target + export route-target"` |
| behavioral | `"<key> = <value>"` — e.g. `"topology = full-mesh"` |
| input-contract (mandatory) | `"Reject omission of <leaf_name>"` |
| input-contract (optional) | `"Accept <leaf_name> present or absent"` |
| lifecycle | fixed strings: `Service create`, `Service modify`, `Service delete`, `Dry-run preview matches actual commit`, `Rollback on commit failure` |
| nfr:encrypted-secrets | `"BGP neighbor password must be encrypted at rest and in device config"` |
| nfr:mtu-honored | `"Configured MTU rendered on PE-CE interface"` |
| nfr:multi-ned | `"Support declared NED types across variants"` |
| nfr:multi-vendor | `"Support declared vendors across variants"` |

---

## Re-run semantics

| Case | Trigger | Behavior |
|------|---------|----------|
| **A** Catalog and lock absent | first run on any system | Apply `af-qa-req-v1`; signature ordering independently assigns the same IDs. Write both artifacts and validate. |
| **B** Catalog and lock match, LLD unchanged | re-run / other system | Verify source hash and signatures; reuse IDs and mappings verbatim. Zero diff. |
| **C** LLD adds stanza/leaf | source edit | **HALT** and report `added requirement`; continue only after `refresh requirements`, which preserves every locked ID and assigns new IDs by sorted signature after the highest existing sequence. |
| **D** LLD edits existing stanza (signature drift) | source edit | **HALT** and report `semantic drift on REQ-<id>`; never silently remap IDs. |
| **E** LLD removes stanza/leaf | source edit | **HALT** and report `removal of REQ-<id>`; never silently delete or reuse IDs. |
| **F** Catalog or lock missing | partial checkout | Rebuild the missing artifact from the LLD and surviving ID map; preserve matching IDs exactly. |
| **G** Source hash differs, every signature/category/priority/`applies_to` unchanged | whitespace/comment/ordering edit | Not a mismatch: update `lld_sha256` in catalog and lock only and continue; IDs, titles, and mappings stay identical. |
| **H** Signature unchanged, optionality, priority, or `applies_to` changed | source edit | **HALT** and report the field diff; continue only after `refresh requirements`, which keeps the ID and updates priority/title/`applies_to` from the rules above so Builder regenerates affected cases. |

Halt on C, D, E, and H prevents silent semantic renaming and coverage gaps.

---

## Mandatory verification (every run)

Run this before Gate 0/1 (Planner) and before Gate 2 (Builder), whether or not the hash matches:

1. Recompute every requirement from the LLD with `af-qa-req-v1`: signature, category, priority,
   `applies_to`, and per-variant `optional`.
2. Compare field by field with `<spec-id>.requirements.yaml` and `<spec-id>.requirements.lock`. The two
   files must list the same IDs and agree with each other, and both must carry `algorithm: af-qa-req-v1`.
3. Any difference (added, removed, or changed requirement; changed priority or `applies_to`; catalog and
   lock disagreeing) **halts the run**. Print the exact diff, write no artifact, and start no later gate.
4. `refresh requirements` is the only operation that rewrites an existing catalog or lock. It preserves
   existing IDs, appends new ones, and never deletes, reuses, or renumbers an ID.
5. `lld_sha256` is informational. If it is the only difference, update that one field and continue.

A missing catalog or lock is rebuilt from the LLD and the surviving file's ID map (case F), then steps
1–3 run against the rebuilt pair.

---

## Workflow

1. Select the LLD file using the input discovery rule above and set
   `<spec-id>` to its filename stem.
2. Parse YAML structurally. Collect service variants, raw-configuration
   stanzas, deployment-model tuples, input leaves, lifecycle operations, and
   evidenced NFR patterns using the fixed categories above.
3. Canonicalize each candidate with `af-qa-req-v1`, fold identical signatures
   across variants, and sort by `(category_rank, signature_sha1)`.
4. Read the prior lock if present. Preserve IDs by signature and run the
   Mandatory verification; halt on any difference and present the diff. Only
   `refresh requirements` may append new signatures. Never silently renumber
   or overwrite the lock.
5. Write `<spec-id>.requirements.yaml` and `<spec-id>.requirements.lock`
   beside the source YAML with matching IDs/signatures, stable key ordering,
   algorithm metadata, and no timestamps.
6. Report the REQ list and source-file path, then continue Planner Gate 0/1
   using the validated IDs; do not wait for approval.

---

## Boundaries

- **In scope:** guiding the Planner through extraction, ID assignment, lock comparison, and drift handling with the selected LLD.
- **Out of scope:** authoring test cases (Builder), running tests (Executor), overriding priority per spec (future sidecar `<spec-id>.requirements.overrides.yaml`).

---

## Safety

- No hardcoded credentials — extractor never reads secrets from the LLD or environment
- No network calls or standalone helper scripts (the one-off hash command above is allowed)
- No timestamps in outputs — determinism guarantee
- Refuses to overwrite a lock without matching signatures or explicit opt-in
