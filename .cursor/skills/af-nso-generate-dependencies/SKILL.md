---
name: af-nso-generate-dependencies
description: 'Regenerate nso-dependencies.yaml from aifirstspec/inputs/*.yaml. Use for: sync dependency matrix after editing a spec, regenerate nso-dependencies.yaml, refresh NSO/NED versions for download_dependencies.sh or CI, run generate_nso_dependencies.sh, update NED version matrix.'
argument-hint: 'e.g. "regenerate nso-dependencies.yaml", "sync dependencies from the selected spec"'
license: Proprietary
---

# NSO Dependency Matrix Generation

Regenerates the repo-root `nso-dependencies.yaml` — the NSO/NED/CXTA version
matrix consumed by `scripts/download_dependencies.sh` (CI dependency download)
and `scripts/pyats_robot_validation.sh` (`cxta:` block) — from the authored
spec files under `aifirstspec/inputs/*.yaml`.

Run this **after** `af-nso-spec-document` creates or edits a spec, whenever the
spec's `nso_version`, `services[]`, or `ned` entries change, and before CI/CD
needs a fresh `nso-dependencies.yaml`.

## Usage

Run from the repo root (all paths are resolved relative to the current
working directory):

```bash
scripts/generate_nso_dependencies.sh
```

Optional overrides — `[SPEC_DIR|SPEC_FILE] [OUTPUT_FILE] [PACKAGES_DIR]`:

```bash
scripts/generate_nso_dependencies.sh \
  aifirstspec/inputs nso-dependencies.yaml packages
```

When `SPEC_DIR` is a directory, only direct `*.yaml`/`*.yml` files whose filename stem contains no `.` are
read. Sidecars named `<spec-id>.<kind>.yaml` (such as `.requirements.yaml`) are skipped.

`PACKAGES_DIR` defaults to `packages`. Each service package directory there
must contain a `package-meta-data.xml`.

> Script is at [./scripts/generate_nso_dependencies.sh](./scripts/generate_nso_dependencies.sh)

## What it reads, per `aifirstspec/inputs/<name>.yaml`

| Spec field | Output field |
|---|---|
| `<name>` (filename) | project key name |
| `project_metadata.version` | project key version (`major.minor`) |
| `development_preferences.nso_version` | `nso-version` |
| `<packages-dir>/*/package-meta-data.xml` `<ncs-package>/<name>` | `nso-packages` (that name, unchanged) |
| `services[].service_variants[].supported_devices[].ned[].{type,version}` (list or single-map form) | `ned-versions` entries: `<type>-cli-<ned-major.minor>  <ned-version>  <nso-version>` |

`cxta-version`/`cxta-image` are not part of the aifirstspec schema — they are
carried forward from the matching project block already in the output file
(if one exists), else default to `CXTA_VERSION`/`CXTA_IMAGE` env vars or
`26.8` / `dockerhub.cisco.com/cxta-docker/cxta`.

One block is written per spec file, so a repo with multiple
`aifirstspec/inputs/*.yaml` files produces multiple project blocks in the
same `nso-dependencies.yaml`.

## Key facts

- **Package names come from the built packages.** `nso-packages` is the
  `<name>` that is a direct child of `<ncs-package>` in each
  `package-meta-data.xml`. Component `<name>` values are ignored. The spec
  `service_name` is not used, so a service called `l3vpn` still lists
  `l3vpn-full-mesh`, `l3vpn-hub-and-spoke-connected`, and
  `l3vpn-hub-and-spoke-static` when those are the package names.
- **Order follows package dependencies.** A `<required-package>` is listed
  before every package that requires it. Packages that do not depend on each
  other stay in directory discovery order. The list is not sorted
  alphabetically. A dependency cycle aborts the run.
- **Errors, not silent skips.** A spec file missing `project_metadata.version`,
  `development_preferences.nso_version`, or any `ned` type/version pair aborts
  the whole run — fix the spec, don't patch the script. A missing packages
  directory, or a package directory with no `<ncs-package>/<name>`, also
  aborts the run.
- **Idempotent for cxta.** Re-running never overwrites a hand-edited
  `cxta-version`/`cxta-image` for a project already present in the file.
- **Portable bash.** Written for bash 3.2 (macOS default) as well as bash 4+
  (CI/Linux) — no `mapfile`/`readarray`.
- After regenerating, `scripts/download_dependencies.sh` reads the new
  `nso-version`/`ned-versions` entries directly — no other step needed.
