---
name: af-qa-cxta-wiring
description: "QA Executor procedure for preparing CXTA from nso-dependencies.yaml and one LLD YAML under aifirstspec/inputs/. Use for testbed assembly, NSO/device/package/secrets checks, preconfiguration, asset readiness, and CXTA execution. No standalone qa/tools scripts; no track-name input."
argument-hint: "optional LLD YAML path under aifirstspec/inputs/; auto-select the sole eligible YAML when omitted"
---

# CXTA Wiring — Agent Procedure

The QA Executor prepares and validates CXTA inputs directly from the selected
LLD. Do not invoke or create standalone `qa/tools/*.py` helpers for these
steps. The selected filename stem is `<spec-id>` and is only an artifact
namespace, not a track.

## Select the LLD

1. Use the explicitly supplied YAML path if it is under `aifirstspec/inputs/`.
2. Otherwise enumerate direct `*.yaml` files there whose filename stem contains
   no `.` (sidecars are named `<spec-id>.<kind>.yaml`).
3. Select the only remaining file. If none or more than one remain, ask for
   the YAML path. Do not ask for a track name.
4. Set `<spec-id>` to the filename without `.yaml`, e.g. `l3vpn.yaml` →
   `l3vpn`.

## Gate 4 Preparation

Perform these checks in order. Stop on the first failure, state evidence, and
give the pipeline/user one actionable correction.

### 1. Validate requirement and test coverage

- Read `<spec-id>.requirements.yaml` and `.requirements.lock` when present.
- Read `qa/01_traceability/<spec-id>_traceability_RTM.csv`,
  `qa/02_testcases/<spec-id>_TestCases_LLD.csv`, and the selected ATP CSV
  when the requested mode is `atp`.
- Verify every REQ has an RTM row, every RTM TCN has at least one LLD test
  case, and every automated case selected for execution has its `.robot`,
  config template, testdata, and required expected template.
- Exclude cases explicitly marked `Manual-only` from Robot execution; report
  them separately. Do not lower the requested mode to make validation pass.
- Confirm TC IDs follow the approved QA Strategy grammar and that REQ IDs
  match the requirements list/lock.

### 2. Verify the frozen runtime contract and testbed

Read `nso-dependencies.yaml`, the selected LLD, the optional map, current NSO
inventory, and Builder outputs:

- `qa/03_cxta_automation/environments/testbed_<spec-id>.yaml`
- `qa/03_cxta_automation/environments/<spec-id>.runtime-contract.yaml`

Builder creates these files. Executor verifies them and never silently
reassembles them. The contract records the canonical suite root, endpoint and
credential env names, exact image/version source, aliases/NSO names/NED IDs,
prerequisite owners, preconfig encoding, and evidence path. Include
`meta.spec_id` and source LLD SHA-256 in the testbed.
Map each LLD device role deterministically to an NSO device using the optional
map first, then role/name matching against live inventory. If the mapping is
ambiguous, ask for a file map; do not invent one.

Include NSO connection values, device aliases/names/NEDs, per-variant address
pools sized for the selected automated cases, defaults evidenced in the LLD,
and environment-variable references for secrets, including the NSO username and
password (`nso.username_env`, `nso.password_env`; see Credentials). The runner
derives host/container-reachable addresses, so do not create a divergent Docker
sibling.

Before writing either file, read `Jenkinsfile`, `scripts/setup_nso_container.sh`,
`scripts/netsim_simulation.sh`, and `scripts/pyats_robot_validation.sh`. Reuse
their variable names. `NSO_HOST`, `NSO_PORT`, and `NSO_RESTCONF_URL` are derived
connection settings, not secrets. Optional `name_env` overrides keep the
testbed device name when unset. Never replace either kind with a random value.

### 3. Runtime preflight

Using RESTCONF/curl and NSO CLI, verify in order:

1. NSO endpoint responds at the generated host and port.
2. The NSO credentials named in the testbed (`nso.username_env`,
   `nso.password_env`) authenticate against RESTCONF. Report the HTTP status
   only.
3. Every service package/NED required by the selected LLD is loaded and
   operational.
4. The service YANG module/container declared by the LLD is queryable.
5. Every generated device name exists in NSO CDB.
6. SSH host keys are present for each device.
7. `sync-from` succeeds for each device.
8. Every environment variable named in the testbed's secret references
   (the NSO login and secrets required by LLD inputs) has a non-empty value. Do
   not print the value. A missing value is a FAIL naming the variable; the
   Executor never generates it (see Credentials).
9. Credentials reach later stages and CXTA, checked without printing a value:
   every name recorded in the testbed is set and non-empty in each later
   Jenkins stage that uses it, and an authenticated RESTCONF request made from
   inside the CXTA container with the forwarded variables returns HTTP 200.
   Report names and PASS/FAIL or the status code only.
10. Each selected automated TC has its required CXTA assets on disk.

Run `bash scripts/validate_cxta_pipeline_contract.sh` before the live checks.
Fix a contract failure in the repository-owned testbed, runner, or pipeline.
Do not ask for manual Jenkins configuration of the disposable NSO environment.

Return a numbered PASS/FAIL report. On any FAIL, do not launch Robot/CXTA.
Preflight is for the selected mode: `full` checks all automated LLD cases;
`atp` checks ATP cases; `smoke` checks smoke-tagged cases.

## Credentials

Applies to the NSO login and every secret named in the testbed.

1. **Source and mapping.** When the pipeline has a Jenkins NSO
   username/password credential, the pipeline binds it and maps its username
   and password onto the environment-variable names the suite reads. Those names
   are recorded in the existing testbed as `nso.username_env` and
   `nso.password_env`, beside the other `*_env` secret references (defaults
   `NSO_RESTCONF_USER` and `NSO_RESTCONF_PASSWORD`, the names the pipeline
   already provides). Read the names from the testbed; do not
   assume them.
2. **Missing credentials, disposable target only.** This applies to password,
   secret, token, and passwd variables. It does not apply to `NSO_HOST`,
   `NSO_PORT`, `NSO_RESTCONF_URL`, or a device `name_env`: those keep the
   runner or testbed value. If the Jenkins credential or the mapped secret is
   absent and the target is the pipeline's own disposable NSO container and
   netsim, generate the value once during that target's setup
   (random, from a cryptographic source, at least 24 alphanumeric characters).
   In the same step provision the matching account: the NSO login with its NACM
   authorization, and the device login when the testbed declares one. Pass the
   value to later stages through the pipeline's masked secret mechanism. A
   persistent or shared target never gets generated credentials; a missing value
   there is a FAIL naming the variable.
3. **One provisioner.** NSO credentials are provisioned once, at target setup.
   Later stages and the CXTA runner must not generate, default or replace them:
   no literal `admin` default and no random per-run fallback for an NSO login,
   because a regenerated value no longer matches the provisioned account.
   Secrets only the disposable target consumes, such as the BGP neighbor
   password, may be generated per run.
4. **Testbed only.** Keep secret references in the existing
   `testbed_<spec-id>.yaml` as environment-variable names
   (`*_env` keys). Values never appear in the testbed, templates, test data or
   any file. No separate env or secrets file is required or created.
5. **No value in any log.** Pass secrets to containers by name only (`-e NAME`,
   never `-e NAME=value`) and keep them off command lines. Do not use `set -x`,
   `env`, `printenv` or any echo of a secret. Report names and PASS/FAIL only.
6. **Post-run leak check.** After a run, search the Jenkins console log,
   `output.xml`, `log.html`, `report.html` and every archived artifact for each
   secret value with fixed-string quiet matching, and report only the number of
   files that match. Any match is a FAIL; replace the value (the target is
   disposable).

The QA Executor verifies this contract; it does not generate or provision
credentials and does not start NSO.

## Device Preconfiguration

Robot setup invokes `NsoLib.Apply Preconfig` with the selected TC's
`preconfig/<TC-ID>.pre.cfg`. The file is JSON with optional top-level `device`
and `config` objects. `device` is patched as JSON; mounted-NED nodes under
`config` are encoded as namespace-aware XML by `preconfig_xml.py`. CLI text,
Jinja `_meta` wrappers, and mounted-NED nodes under `device` are invalid.
Preconfig must be idempotent and teardown must restore it when it is
test-owned. If Gate 2 declares prerequisite state, a missing matching
preconfig/shared-prerequisite declaration is a FAIL, not a reason to continue.

## Execute

Only after coverage, generated testbed, runtime, secret, and asset checks pass:

```text
bash scripts/validate_cxta_pipeline_contract.sh
RUN_MODE=<full|atp|smoke> bash scripts/pyats_robot_validation.sh
```

Mode defaults to `full`; ATP and smoke are explicit. These are the Jenkins
entry points and therefore the only authoritative local execution path.

## Pipeline Responsibilities

The pipeline brings up NSO, install/reloads packages declared
by the selected LLD and `nso-dependencies.yaml`, onboard the devices, fetch SSH
keys, sync-from, and supply credentials: bind the Jenkins NSO username/password
credential and map it to the names in the testbed, generate any missing
credential during disposable-target setup and provision the matching account
there, and pass the values to later stages and CXTA without logging them (see
Credentials). The QA Executor derives the remaining CXTA wiring from the
selected spec file. It must run the contract validator immediately before the
CXTA runner.
