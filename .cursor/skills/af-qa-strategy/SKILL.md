---
name: af-qa-strategy
description: 'Generate QA Strategy from nso-dependencies.yaml and the selected LLD YAML file directly under aifirstspec/inputs/. Use for QA strategy, naming grammar, gate mapping, and KPI targets. No track selector.'
argument-hint: 'optional LLD YAML path under aifirstspec/inputs/; auto-selects the sole eligible file'
license: Proprietary
---

# QA Strategy Generation

Produces `qa/00_inputs/strategy/<project>_QA_Strategy.md` — one project-wide document covering
the service requirements in the selected LLD YAML file under `aifirstspec/inputs/`.

> **Structure template:** [references/strategy-template.md](./references/strategy-template.md)

---

## When to use

- User asks to **generate**, **create**, or **regenerate** QA strategy
- Planner Action 1 — before Gate 0 (variations) or Gate 1 (RTM)
- Project scope changes (new LLD input files, NEDs, deployment models)

**Other roles:** Builder, Executor, and Reporter read **sections only** from the
generated strategy (or from `references/strategy-template.md` if strategy is
missing) — see [Section lookup](#section-lookup-for-other-roles).

---

## Inputs (authoritative — do not add others for strategy generation)

| Input | Path | Use |
|-------|------|-----|
| Project spec | `nso-dependencies.yaml` (repo root) | Identity, NSO version, NED, topology, service type |
| LLD spec | selected `aifirstspec/inputs/<spec-id>.yaml` | Variants, requirements, `instance_variables`, `raw_configuration`, NED/device roles |

**Do not** read OpenSpec, external LLD, or reference design docs when generating
the strategy. If information is missing, document it in **Gap Analysis** (Section 4)
and ask the user — do not infer from platform capability specs.

If either file is missing, halt and ask the user — the only authoritative
inputs are `nso-dependencies.yaml` (repo root) and the selected LLD YAML directly under `aifirstspec/inputs/`.
Do not fall back to any other location.

---

## Workflow

### 1. Load inputs

```text
nso-dependencies.yaml                # repo root
<selected LLD YAML>                  # direct child of aifirstspec/inputs/
```

Read [references/strategy-template.md](./references/strategy-template.md) — every
time, not from memory.

### 2. Phase 1 — Collect project information

From `nso-dependencies.yaml` and the selected LLD YAML, extract:

- Project identity, service names, NSO version, NEDs
- Project type (greenfield / brownfield / migration / CI-CD)
- Functional scope per variant (`service_variants`, subtypes)
- NFRs implied by the selected LLD (scale, vendors, environments)
- Architecture patterns present in the selected LLD (FASTMAP, templates, callbacks, CWM only if specified)

For project identity, prefer `project_metadata.project_name` in
`nso-dependencies.yaml`. If it is absent, use the selected LLD's
`project_metadata.project_name`; record the missing dependency metadata and any
conflicting dependency-block label in Gap Analysis, and continue without an
approval pause. If neither source has a project name, use `<spec-id>` for the
strategy filename and record the identity gap.

Ask the user only for gaps **not** present in those two input types.

### 3. Phase 2 — Requirement analysis

- Categorize FR/NFR from the selected LLD
- Business rules, dependencies, assumptions, risks
- Flag missing information for Gap Analysis

### 4. Phase 3 — Project classification

| Dimension | Values |
|-----------|--------|
| Complexity | Low / Medium / High |
| Criticality | Low / Medium / High |
| Deployment | Greenfield / Brownfield / Migration |
| Automation potential | Low / Medium / High |
| Technology | NSO / CWM / Hybrid (only if selected LLD indicates CWM) |
| Network | Single / Multi vendor |
| Scale | Small / Medium / Large |

### 5. Phase 4 — Strategy decision engine

| If… (from selected LLD) | Include in strategy |
|------------------------|---------------------|
| Brownfield variants | Drift testing, sync-from, rollback, reconciliation |
| Reactive FASTMAP / nano services | Plan state, lifecycle, failure injection, recovery |
| Multi-vendor / multi-NED | NED matrix, per-vendor template validation |
| HA (if specified in selected LLD) | Failover, resilience, split-brain |
| Scale > 1000 devices | Performance, concurrency, commit queue |
| Migration scope | Upgrade/downgrade, data migration, coexistence |
| CWM (if in selected LLD) | Workflow lifecycle, CWM–NSO integration, LCM |
| CI/CD expectation | BVT, pipeline gates, deployment validation |

Do not add rows for capabilities not evidenced in `nso-dependencies.yaml` or the selected LLD.

### 6. Phase 5 — Write document

**Output:** `qa/00_inputs/strategy/<project>_QA_Strategy.md`

Derive `<project>` from `nso-dependencies.yaml` `project_metadata.project_name`,
falling back to the selected LLD's `project_metadata.project_name`, then
`<spec-id>`; sanitize the selected value for the filename (e.g.
`Sample_CNC_NSO1.0`).

Fill all **22 sections** per the template. Check the validation checklist in
[strategy-template.md](./references/strategy-template.md) before presenting.

Validate the completed strategy against the template, then let Planner proceed to Gate 0 or Gate 1 without an approval pause. Regenerate only when project scope changes (new LLD input files, NEDs, deployment models).

---

## Section lookup for other roles

When the project strategy file exists, read **only** the needed section from
`qa/00_inputs/strategy/<project>_QA_Strategy.md`. If missing, use the matching section in
[references/strategy-template.md](./references/strategy-template.md):

| Role | Sections |
|------|----------|
| Builder | §13 Naming Grammar, §14 Testing-Type Tags, §19 Test Asset Layout |
| Executor | §14 Testing-Type Tags (Robot tag vocabulary) |
| Reporter | §21 Metrics, KPIs, Deliverables, Schedule |

---

## Document rules

1. Every recommendation traces to a requirement or risk from the selected LLD.
2. NSO-aware where the selected LLD implies NSO service behaviour.
3. Measurable thresholds for gates and KPIs.
4. Actionable for Builder and Executor downstream.
5. Never copy another project's business scope, Jira project, or RACI names.

---

## Safety

- No hardcoded credentials in strategy examples
- Secrets policy in Section 17 / 18 — env vars and testbed references only
