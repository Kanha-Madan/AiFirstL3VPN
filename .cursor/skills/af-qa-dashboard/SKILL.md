---
name: af-qa-dashboard
description: 'Build QA KPI dashboard HTML from CXTA Robot output. Use for: generate dashboard HTML, qa dashboard, KPI dashboard, Gate 6 HTML report, build_dashboard.py, qa_dashboard.html, pass-rate trend, results by flavour. Invoked by QA Reporter after execution (and optional triage). Read-only over artifacts — does not run tests.'
argument-hint: 'spec-id + run_id or path to qa/04_test_execution/<run_id>/'
license: Proprietary
---

# QA Dashboard (HTML + results.json)

Produces the **visual KPI dashboard** (dark-theme HTML matching the AIQAFramework
`qa_dashboard.html` layout) from Robot `output.xml` and the selected spec's RTM.

Markdown KPI narratives (`<spec-id>_dashboard_<timestamp>.md`) remain **Reporter
agent prose** — this skill owns the **HTML**, `results.json`, and trend history.

> **Script:** [qa/06_dashboard/build_dashboard.py](../../../qa/06_dashboard/build_dashboard.py)

---

## When to use

- **Gate 6** — after `qa/04_test_execution/<run_id>/output.xml` exists
- User asks for **dashboard HTML**, **qa_dashboard.html**, or **KPI chart**
- CI publishes dashboard artifacts post-test

**Do not use** when execution artifacts are missing — hand off to **Executor**
(`run CXTA tests` with the selected LLD file; full catalog by default, or `run ATP tests` only when ATP is explicitly requested).

---

## Prerequisites

| Artifact | Path |
|----------|------|
| Robot results | `qa/04_test_execution/<run_id>/output.xml` |
| Run summary (optional) | `qa/04_test_execution/<run_id>/execution_summary.yaml` |
| RTM | `qa/01_traceability/<spec-id>_traceability_RTM.csv` |
| Triage (optional) | `qa/05_result_triage/<spec-id>_triage_*.md` — informs markdown KPIs, not required for HTML |

---

## Workflow

### 1. Resolve run directory

- User provides `{run_id}` → `qa/04_test_execution/{run_id}/`
- Else use **latest** directory under `qa/04_test_execution/` that contains `output.xml`

### 2. Run the builder script

From repo root (`nso-code-template/`):

```bash
# Latest run (default)
python3 qa/06_dashboard/build_dashboard.py

# Specific run
python3 qa/06_dashboard/build_dashboard.py \
  --run-dir qa/04_test_execution/<run_id>

# Explicit RTM / output dir
python3 qa/06_dashboard/build_dashboard.py \
  --run-dir qa/04_test_execution/<run_id> \
  --rtm qa/01_traceability/<spec-id>_traceability_RTM.csv \
  --track L3VPN
```

### 3. Verify outputs

| File | Purpose |
|------|---------|
| `qa/06_dashboard/qa_dashboard.html` | Canonical dashboard (open in browser) |
| `qa/06_dashboard/<spec-id>_dashboard_<timestamp>.html` | Timestamped copy |
| `qa/06_dashboard/results.json` | Machine-readable KPIs for portfolio rollup |
| `qa/06_dashboard/run_history.json` | Pass-rate trend (2+ runs → SVG chart) |

### 4. Reporter markdown (same Gate 6)

After HTML succeeds, write `qa/06_dashboard/<spec-id>_dashboard_<timestamp>.md`
per **Reporter agent** — KPI table, recommendations, release readiness.
Cross-link HTML: `qa/06_dashboard/qa_dashboard.html`.

---

## CLI reference

| Flag | Default | Description |
|------|---------|-------------|
| `--run-dir` | Latest under `qa/04_test_execution/` | Folder with `output.xml` |
| `--rtm` | `qa/01_traceability/l3vpn_traceability_RTM.csv` | RTM for TCN/priority/flavour |
| `--out-dir` | `qa/06_dashboard/` | Dashboard output directory |
| `--track` | `L3VPN` | Title tag in HTML |
| `--history` | `qa/06_dashboard/run_history.json` | Trend history file |

Exit code `0` on success; `1` if `output.xml` missing.

---

## HTML contents (do not hand-roll)

The script renders:

- Donut + KPI cards (pass rate, tests, P0 pass rate, RTM coverage, new failures, flaky)
- Pass-rate trend (from `run_history.json`)
- Results by flavour (variant code: FMESH / HSCON / HSSTA)
- Failures / defects table
- Embedded `DATA` JSON for tooling

**Do not** duplicate this layout in agent-generated HTML — always delegate to the script.

---

## Integration with portfolio (A7)

`results.json` → `summary` block feeds a multi-spec portfolio when multiple LLD files are explicitly in scope.
Reporter reads latest `results.json` or markdown KPI lines per selected spec file.

---

## Safety

- Read-only — no NSO, Docker, or test execution
- Redact credentials if copying failure messages into markdown narratives
- Do not commit secrets from `execution_summary.yaml` into published dashboards
