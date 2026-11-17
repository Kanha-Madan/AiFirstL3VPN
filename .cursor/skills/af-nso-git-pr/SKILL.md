---
name: af-nso-git-pr
description: 'Publish a validated Cisco NSO spec build to git. Use for: create branch for service packages, commit generated packages, push packages, raise PR, open pull request for NSO service build, publish spec build, git branch commit PR for packages, run git_pr_publish.sh. Only publishes when ALL service variants pass validation; commits only packages/ paths; requires human confirmation at push and PR.'
argument-hint: 'service name + package paths from a completed, validated spec build'
license: Proprietary
---

# NSO Git Publish (Branch → Commit → Push → PR)

Publishes a **completed, fully-validated** NSO spec build as a reviewable pull
request. It is the git "publish" step for the
[af-nso-spec-orchestrator](../af-nso-spec-orchestrator/SKILL.md) — invoked as its
**Phase D**, top-level and serial, after Phase C validation.

This skill only ever runs when a build is green. It never fixes packages, never
starts NSO, and never bypasses the human confirmations at push and PR.

> Helper script: [scripts/git_pr_publish.sh](./scripts/git_pr_publish.sh)

---

## Inputs

- **service** *(required)*: the primary service name for the build, used in the
  branch name. Derive from the spec's primary `service_name` (or spec filename).
- **package paths** *(required, one or more)*: the `packages/<name>/` directories
  produced by this build. These form the commit **allow-list**.
- **validation result** *(required)*: the per-variant PASS/FAIL outcome from
  Phase C. Publishing proceeds **only if every variant passed**.
- **base branch** *(optional)*: defaults to the `origin` default branch (detected,
  normally `main`).

---

## Guardrail — publish only fully-validated builds (all-or-nothing)

Before doing anything with git, confirm **every** variant passed Phase C
validation.

- **All variants PASS** → proceed to the workflow below.
- **Any variant FAIL** → **halt**. Do **not** create a branch, do **not** commit.
  Leave the working tree and `main` untouched so the user can inspect the failed
  variants. Report which variants failed.

There is no partial publish: a build is published as a whole or not at all.

---

## Workflow

Run the steps in order. Branch creation and commit run **automatically** once the
guardrail passes; **push and PR each require explicit human confirmation**.

### Step 0 — Preflight

```bash
# gh present + authenticated (PR step needs it)
command -v gh >/dev/null || echo "gh missing"
gh auth status || echo "gh not authenticated"

# detect the origin default branch (base for the PR); default to main
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's#refs/remotes/origin/##'
```

- Confirm the working tree contains the expected new files under each
  `packages/<name>/` path.
- If `gh` is missing or unauthenticated, you may still branch + commit, but the PR
  step falls back to manual (see **Manual fallback**).

### Step 1 — Create the branch (after validation, automatic)

Files were authored on `main` (uncommitted) during Phases B/C. Create the branch
**now**, carrying those changes onto it without committing to `main`:

```bash
git switch -c feature/<service>-<yyyymmdd>
```

- Name: **`feature/<service>-<yyyymmdd>`** — one branch per spec build.
- **Collision:** if `feature/<service>-<yyyymmdd>` already exists locally or on
  `origin`, reuse it if it is unpushed/appendable; otherwise append a numeric
  suffix (`-2`, `-3`, …) instead of failing.
- `main` receives **no** commit.

### Step 2 — Commit (path allow-list, automatic)

Stage **only** the build-produced package paths — never `git add -A`:

```bash
git add -- packages/<name-1>/ packages/<name-2>/     # allow-list only
git commit -m "Add NSO service package(s): <name-1>, <name-2>"
```

- **Never** stage arbitrary working-tree changes, rendered device configs, logs,
  or scratch files — they are outside the allow-list and stay uncommitted.
- **Never persist secrets.** Credential values used during the build are never
  committed; verify no rendered config containing secrets is inside a staged path.

### Step 3 — Push (HUMAN CONFIRMATION REQUIRED)

Show the exact command and a short summary (branch, files, commit subject), then
**wait for the user to confirm** before running:

```bash
git push -u origin feature/<service>-<yyyymmdd>
```

- If the user declines → stop. Leave the committed branch in place and report its
  name so they can push later. Do not force.

### Step 4 — Open PR (HUMAN CONFIRMATION REQUIRED)

Show the target base branch and the PR title + short body, then **wait for the
user to confirm** before running:

```bash
gh pr create --base <default-branch> \
  --head feature/<service>-<yyyymmdd> \
  --title "<short title>" \
  --body-file <short-body-file>
```

- Base is the detected `origin` default (normally `main`).
- Body is **short**, auto-generated from the build report: services built, package
  names, and a one-line validation summary. No secrets.
- Capture and return the **PR URL**.
- If the user declines → stop after the push; report the pushed branch and the
  compare URL so they can open the PR manually.

### Step 5 — Report back

Return to the orchestrator: the **branch name** and the **PR URL** (or the pushed
branch + compare URL if the PR was declined) for inclusion in the Step 7 report.

---

## Manual fallback (gh unavailable / unauthenticated)

If `gh` is missing or `gh auth status` fails, complete Steps 1–3 (branch, commit,
and — with confirmation — push), then **stop** and print for the user:

- the branch name,
- the `git push -u origin <branch>` command (if not already pushed),
- the compare URL: `https://github.com/<owner>/<repo>/compare/<base>...<branch>`

so a human can open the PR in the browser.

---

## Using the helper script

[scripts/git_pr_publish.sh](./scripts/git_pr_publish.sh) wraps the git mechanics
in three actions so the agent keeps the human gates:

```bash
# prepare: preflight + create branch + allow-listed commit (no push)
scripts/git_pr_publish.sh prepare --service l3vpn \
  --package packages/l3vpn-full-mesh --package packages/l3vpn-hub-spoke

# push: after human confirmation
scripts/git_pr_publish.sh push --branch feature/l3vpn-20260709

# pr: after human confirmation (short body from a file)
scripts/git_pr_publish.sh pr --branch feature/l3vpn-20260709 \
  --title "Add NSO service packages: l3vpn" --body-file /tmp/pr-body.md
```

The script performs the allow-list commit, collision-safe branch naming, and base
detection; it never runs `push` or `pr` unless you invoke those actions
explicitly (that is where the agent inserts the human confirmation).

---

## Key rules

- **Green builds only.** All variants must pass validation; otherwise no branch,
  no commit — halt and report.
- **Branch after validation.** Author on `main` (uncommitted), branch only once
  green; `main` never receives a commit.
- **Allow-list commits.** Stage only `packages/<name>/` paths — never `git add -A`.
- **Never persist secrets.** No credentials or secret-bearing rendered config in
  any commit or PR body.
- **Human gate at push and PR.** Branch/commit are automatic; push and PR each
  require explicit confirmation, and declining leaves the branch intact.
- **One branch + one PR per spec build**, targeting the `origin` default (`main`).
- **Top-level and serial.** Runs as the orchestrator's Phase D — never inside an
  authoring subagent.
