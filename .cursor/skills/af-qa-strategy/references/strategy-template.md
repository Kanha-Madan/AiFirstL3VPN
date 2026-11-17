# QA Strategy — Required Structure Template

Use when generating `qa/00_inputs/strategy/<project>_QA_Strategy.md`.  
**Read before every strategy write** — do not rely on memory. Validate the strategy before use; strategy generation is not an approval gate.

A prior framework run claimed a naming grammar in its Executive Summary and never defined it. Every generated strategy must include the sections below with **concrete, project-specific content**.

---

## Required sections (22)

Check each section off before the strategy is used by Planner or Builder.

| # | Section | Must include |
|---|---------|--------------|
| 1 | **Executive Summary** | Project, selected LLD files, deployment class, test approach, gate summary |
| 2 | **Project Overview** | Identity table, classification (complexity, criticality, scale), source conflicts |
| 3 | **Requirement Analysis** | FR table (ID, text, variants, trace to selected LLD) |
| 4 | **Gap Analysis** | Open gaps with owner; missing inputs that would change strategy |
| 5 | **Assumptions** | Numbered list tied to project sources |
| 6 | **Dependencies** | Table: dependency, type, impact if missing |
| 7 | **Constraints** | Table: constraint, testing impact |
| 8 | **Scope — In Scope** | Table by area, variants, requirement IDs |
| 9 | **Scope — Out of Scope** | Table with reason per excluded area |
| 10 | **Risk Assessment** | Risk table (ID, prob, impact, mitigation → tests); P0/P1/P2 rules |
| 11 | **Test Strategy & Approach** | Principles (variant-driven, selected-LLD oracle, brownfield-first, no stubs) |
| 12 | **Test Levels** | Unit, integration, system, UAT — scope, tools, coverage, gate trigger |
| 13 | **Naming Grammar** | TCN and TC patterns; FLAVOR/FEATURE-CODES tables; NNNN block-of-50 rule; examples |
| 14 | **Test Dimensions & Testing-Type Tags** | D1–D4 axes; variation types (positive/negative/error/boundary); feature codes as Robot tags (never extra TCNs) |
| 15 | **Functional & NSO-Specific Validation** | Per-variant matrix; brownfield/sync/redeploy; nano/plan (if applicable) |
| 16 | **Regression & Automation Strategy** | Regression triggers; automation split; CI/CD jobs |
| 17 | **Environment & Test Data Strategy** | Env table; test data sources; secret handling |
| 18 | **Performance & Security Strategy** | Metrics + targets; auth, secrets, input validation |
| 19 | **Test Asset Layout** | `qa/` tree through Gate 3; scripts/config/expected per TCN-mirrored FLAVOR folder |
| 20 | **Entry / Exit Criteria & Quality Gates** | Entry per level; exit pass criteria; Gate 0–6 + A7 mapping |
| 21 | **Metrics, KPIs, Deliverables, Schedule** | KPI targets; artifact paths; indicative timeline |
| 22 | **Release Readiness, Recommendations, Decision Record** | Checklist; traced recommendations; optional decision record (not a planning gate) |

---

## Structure-fixed boilerplate (customize values, keep headings)

### Naming grammar (Section 13 — required verbatim pattern)

```
TCN:  TC.<SERVICE>.<PLATFORM>.<FUNCTION>.<FLAVOR>.<FEATURE-CODES>
TC:   TC.<SERVICE>.<PLATFORM>.<FUNCTION>.<FLAVOR>.<FEATURE-CODES>.<NNNN>
```

- Planner assigns **TCN** IDs; Builder assigns **NNNN** (block-of-50 per TCN).
- Do not use deprecated `vocab.json`.
- Reproduce the Planner's Table A exactly: one TCN per LLD subtype with suffix `CRTE.MOD.DRYRUN.DEL.RLBK` and the FLAVOR computed by its rule. Do not define other TCN patterns or per-feature TCNs; feature codes are Robot tags only.

### Testing-type tags (Section 14)

| Tag | Use |
|-----|-----|
| positive | Happy-path provision / verify |
| negative | Invalid input rejected |
| error | Device unreachable, transaction conflict |
| boundary | Min/max limits, optional field omitted vs present |

### Quality gates — CI/CD mapping (Section 20)

| Gate | Role | Artifact | Typical CI trigger |
|------|------|----------|-------------------|
| — | Planner | `qa/00_inputs/strategy/<project>_QA_Strategy.md` | Fail build if missing on first plan |
| 0 | Planner | `qa/01_traceability/<spec-id>_variations.csv` | Structural and requirement-coverage validation; no approval gate |
| 1 | Planner | `qa/01_traceability/<spec-id>_traceability_RTM.csv` | Schema, TCN uniqueness, and coverage validation; no approval gate |
| 2 | Builder | `qa/02_testcases/<spec-id>_TestCases_LLD.csv` | PR review |
| 2b | Builder | `qa/02_testcases/<spec-id>_ATP_TestCases.csv` and `qa/02_testcases/<spec-id>_ATP_TestPlan.docx` | PR review |
| 3 | Builder | `qa/03_cxta_automation/tests/…` | PR merge |
| 4 | Executor | `qa/04_test_execution/` | Nightly / RC |
| 5 | Executor | `qa/05_result_triage/` | Post-run |
| 6 | Reporter | `qa/06_dashboard/` | Release |
| A7 | Reporter | Portfolio (multiple selected LLD files) | Release |

### Defect workflow (Section 20 or 22)

| Triage class | Action |
|--------------|--------|
| Product bug | Jira defect with TC ID, TCN, steps, expected vs actual |
| Test bug | Fix script/data; re-run Gate 4 |
| Environment | Fix testbed; do not close product bugs |
| Known issue | Link existing Jira; exclude from ATP pass rate if accepted |

### Test asset layout (Section 19)

```
qa/
├── 00_inputs/
│   └── strategy/<project>_QA_Strategy.md
├── 01_traceability/
├── 02_testcases/
├── 03_cxta_automation/tests/<SERVICE>/<PLATFORM>/
│   ├── testdata/<TC-ID>.yaml
│   └── <FUNCTION>/<FLAVOR>/
│       ├── scripts/<TC-ID>.robot
│       ├── config/<TC-ID>.cfg.j2
│       ├── preconfig/<TC-ID>.pre.cfg
│       └── expected/<TC-ID>.expected.j2
├── 04_test_execution/
├── 05_result_triage/
└── 06_dashboard/
```

Gate 2 **TestCase Template Builder** depends on Section 13 (naming), Section 14 (dimensions/types), and Section 15 (expected results trace to the selected LLD `raw_configuration`).

Section 17 must also classify every runtime dependency as
`pipeline-provided`, `suite-created`, `shared-prerequisite`, or `unresolved`,
including endpoint variables, credential references, package/NED identity,
device mapping, and prerequisite state. `unresolved` blocks Builder handoff.
Section 19 requires a generated
`qa/03_cxta_automation/environments/<spec-id>.runtime-contract.yaml`.

---

## Document rules (all strategies)

1. Every recommendation traces to a requirement or risk.
2. NSO-aware: FASTMAP, nano services, sync, NED, templates, callbacks, CDB, NACM.
3. Measurable thresholds for gates and KPIs.
4. Actionable for Builder and Executor downstream.
5. Reuse another project's reference SDD for **structure only** — never copy business scope, Jira project name, or RACI names.
6. Do not invent OSPF, CWM, or HA testing unless the selected LLD includes them.

---

## Validation checklist (before use)

- [ ] All 22 sections present with project-specific content
- [ ] Naming grammar defined with FLAVOR/FEATURE tables (not only mentioned in Executive Summary)
- [ ] Every FR has variant coverage or explicit out-of-scope reason
- [ ] Gate artifacts use paths under `qa/00_inputs/strategy/` and `qa/01_traceability/` … `qa/06_dashboard/`
- [ ] Secrets policy stated (no hardcoded passwords in test assets)
- [ ] Runtime dependencies have an owner; none remain unresolved
- [ ] Gaps and source conflicts documented with QA stance
