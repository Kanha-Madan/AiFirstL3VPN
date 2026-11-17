---
name: af-nso-spec-document
description: 'Generates a YAML-style NSO project requirements spec from any input source. Use for: generate spec, create spec document, convert requirements to spec, build service spec, spec from Excel, spec from config, spec from Word, create project requirements. Always scans for <VARIABLE> tokens before asking questions. Covers: multi-variant services, instance_variables per variant, raw configuration preservation, clarifying questions for missing fields, variable detection and deduplication, shared variable annotation.'
argument-hint: 'input source and optional output filename — e.g. "convert this Excel sheet to spec", "create spec from this config", "generate spec document as <name>.yaml"'
license: Proprietary
---

# Spec Document Generator

## Purpose

Create a YAML-style project requirements spec matching this repository's `Project Requirements.txt` format. The source can be any requirement input: pasted text, a command-style prompt, a spreadsheet, a Word document, a table, raw network configuration, screenshots converted to text, or mixed notes.

## Variable Detection

Any value written as `<VARIABLE_NAME>` in the input (angular-bracket notation) is a **parameterized instance variable**, not a missing field.

Rules:
- Scan the entire input (all cells, headings, config lines, prose) for `<...>` tokens before doing anything else.
- Collect variables **per service variant** — each variant gets its own `instance_variables:` block containing only the tokens that appear in that variant's config.
- **Never ask the user about these during spec creation.** They are intentional per-instance placeholders.
- Preserve them exactly as `<VARIABLE_NAME>` inside `raw_configuration` blocks.
- For each variant, emit an `instance_variables:` key-value map **immediately before** `raw_configuration:`. Format: `lowercase_snake_key: "<ORIGINAL_TOKEN>"  # inferred description`. Read `template.md` for the exact format.
- If the same token appears with different casings (e.g. `<VRF_Name>` and `<vrf_name>`), treat them as one variable normalised to `UPPERCASE_WITH_UNDERSCORES` for the value and `lowercase_snake_case` for the key.
- If the same variable token appears in **multiple variants**, emit it in each variant's `instance_variables:` and add the comment `# shared across variants` on that line.

## Workflow

1. Gather input:
   - If the user provides text or a command-style request, use it directly.
   - **If the user has no source material** (a generic "build me an X service" ask), the **af-nso-service-requirements** skill runs first (Stage-1 elicitation front-end) and produces `input-configs/<service>-requirements.md` plus per-role `input-configs/<service>-<role>.cfg` files. Read those as the source input — the per-role configs already carry `<PLACEHOLDER>`/`<VARIABLE>` tokens for parameters.
   - If the user provides a file, read it using the preinstalled Python libraries based on file type:
     - `.xlsx` (Excel)              → `openpyxl`   — `load_workbook(path, data_only=True)`
     - `.docx` (Word)               → `python-docx` — `Document(path)`, iterate `.paragraphs` and `.tables`
     - `.yaml` / `.yml`             → `PyYAML`      — `yaml.safe_load(open(path))`
     - `.txt` / `.cfg` / raw config → `chardet`     — detect encoding first, then `Path(path).read_text(encoding=detected)`, or fall back to `Path(path).read_text(errors='replace')` if chardet is unavailable
   - **Python environment for reading files.** Reading `.xlsx`/`.docx` needs `openpyxl` / `python-docx` (and `PyYAML`/`chardet` for YAML/raw config). Resolve the interpreter in this order — **never create a `.venv` inside the skill directory** (it lives under `.cursor/`/`.github/`, which are committed, so a venv there pollutes the user's repo):
     1. **Use the ambient interpreter if it already has the libs.** If `python3 -c "import openpyxl, docx, yaml"` succeeds, just use `python3` directly — no venv needed. Most developers building Python NSO packages already have Python 3 (macOS ships it).
     2. **Otherwise install into a user-level cache venv, outside the project.** Create/reuse a venv under the aifirst cache and install this skill's pinned recipe:
        ```bash
        AF_VENV="${XDG_CACHE_HOME:-$HOME/.cache}/aifirst/spec-document-venv"
        [ -x "$AF_VENV/bin/python" ] || python3 -m venv "$AF_VENV"
        "$AF_VENV/bin/pip" install -q -r assets/requirements.txt   # assets/ is this skill's bundled recipe
        ```
        Then read inputs with `"$AF_VENV/bin/python"`. This keeps the venv out of the repo entirely — no `.gitignore` entry needed.
     3. **If `python3` is unavailable**, tell the user to install Python 3 and the libraries in `assets/requirements.txt` (macOS ships `python3`; otherwise python.org or `brew install python`), then continue.
   - Do not assume any fixed spreadsheet columns, sheet names, document headings, or table layout.
   - Treat the input as source evidence, not as a rigid schema.

2. Detect variables (run before identifying facts):
   - Find all `<VARIABLE_NAME>` tokens in the input.
   - Group them per service variant — track which tokens appear in which variant's config block.
   - Infer a short description for each token from the config keyword immediately preceding it (e.g. `vrf <VRF_NAME>` → "VRF name for the service instance").
   - Mark any token that appears in more than one variant as shared.
   - These variables are **resolved** — do not include them in clarification questions.

3. Identify source facts:
   - Project metadata: project name, version, description.
   - Development preferences: NSO version, NED type(s), package structure, code pattern.
   - Network context: standalone or LSA topology.
   - Devices: role, vendor, model, OS version, management IP.
   - Services: service name, variants, deployment model, routing protocol, topology.
   - NED details: type and version per supported device.
   - Raw configuration blocks per service variant/device.
   - Any field whose value in the input is a `<variable>` token is already resolved — do not ask about it.

4. Map source material into the output template:
   - Read `template.md` for the required structure, including the `instance_variables:` format inside each variant.
   - Use service variant names from any available evidence: headings, labels, rows, prose, filenames, command text, or raw config context.
   - Preserve raw network configuration exactly, including indentation, comments, `!` separators, VRF/interface/BGP blocks, vendor syntax, and `<VARIABLE_NAME>` tokens.
   - Do not invent device model, OS, NED version, management IP, NSO version, or package preferences.
   - If the input format is ambiguous, explain the interpretation and ask the user to confirm before finalizing.

5. Generate the spec skeleton:
   - Output valid YAML-style text using two-space indentation.
   - Quote scalar values.
   - Use block scalar `|` for raw configuration.
   - Populate every field from the source input first; only fall back to a value supplied directly by the user in this conversation.
   - For any non-variable field that is still unresolved after using the source input, write `REPLACE_ME`. These placeholders are expected at this stage — they are collected from the user in step 7 via the interactive form, not by asking in chat.
   - **Do not treat any `<VARIABLE_NAME>` token as a missing field.** Preserve it exactly; it is never a `REPLACE_ME` and never enters the form.
   - Include all service variants found in the input.
   - Inside each variant block, place `instance_variables:` immediately before `raw_configuration:`. Omit the block entirely for variants that have no `<...>` tokens.

6. Save the spec skeleton:
   - Ensure the package-memory store exists first (idempotent): `aifirst spec init`.
   - Write the generated spec to `aifirstspec/inputs/<descriptive-name>.yaml` (create the `aifirstspec/inputs/` directory if it does not already exist). This is the agent-authored working input — it lives alongside the store but is not a CLI-managed file; step 9 ingests it into the store proper.
   - Choose `<descriptive-name>` from the project name or source filename in kebab/snake case; avoid overwriting an existing file unless the user confirms replacing it.
   - Saving with `REPLACE_ME` placeholders is expected here, because step 7 resolves them in place. (This is the one sanctioned case for writing `REPLACE_ME` to disk.)

7. Collect missing values with the interactive form (`aifirst collect`):
   - Resolve every `REPLACE_ME` by running the CLI form collector against the saved file. This replaces chat-based Q&A for missing fields.
   - Run the command and **wait for it to return** (it blocks until the user submits or cancels the browser form):

     ```bash
     aifirst collect --spec aifirstspec/inputs/<descriptive-name>.yaml
     ```

   - The command prints a local URL, opens the browser form, and blocks. Tell the user the browser form is open and the terminal is waiting for their submission. Expected console output:

     ```text
     Serving collect form at http://127.0.0.1:<port>/
     Waiting for the user to fill out and submit the form at http://127.0.0.1:<port>/ ...
     (the command will return once the form is submitted or cancelled)
     Collected values written to aifirstspec/inputs/<descriptive-name>.yaml
     ```

   - On success the command writes the submitted values back into the same file in place and exits 0. Re-read the file and continue.
   - `<VARIABLE_NAME>` tokens are never part of the form and stay untouched. The form never renders secret fields.
   - **Fallback (rare):** only if `aifirst collect` is not installed, exits with a cancelled/browser-unavailable code, or the environment has no browser, fall back to chat clarifying questions using `clarification-checklist.md`.
   - **Mandatory resolution rule:** every non-variable field must end up filled with a real value — from the source input, from the submitted form, or (in the fallback path) from a direct user answer. Do not leave the finalized spec with any `REPLACE_ME` unless the user was asked about that specific field and explicitly said to leave it unresolved. A generic "go ahead" or "proceed" is not authorization to leave `REPLACE_ME` in place.

8. Security handling:
   - Never ask the user for plaintext passwords, secrets, tokens, or private keys.
   - If raw config includes encrypted/hashed password lines, preserve them only when they came from the source input and flag them for user review.
   - Do not create or hardcode new credentials.

9. Human review gate — STOP and get confirmation before building:
   - The finalized `aifirstspec/inputs/<descriptive-name>.yaml` is the deliverable; it already lives inside the store's inputs area.
   - **Stop here and hand the spec to the human for review.** Present the file path and a concise summary — services, variants, NSO/NED versions, device roles, and the instance-variable keys per variant — then ask them to open `aifirstspec/inputs/<descriptive-name>.yaml`, review/edit it, and **explicitly confirm** before any build proceeds. This is a distinct checkpoint: do **not** treat an earlier generic "go ahead" as approval of the generated spec.
   - **Do not run `aifirst spec change new` or `change archive` in this skill** — the orchestrator owns the change lifecycle (opening a change here would collide with its `change new`).
   - **Only after explicit human confirmation**, hand the spec path to **af-nso-spec-orchestrator** to build. If the human requests changes, edit `inputs/<name>.yaml` (or re-run collection) and re-present it for review. If they only wanted the spec, stop — it is ready for a later build.
   - Full flow: [af-nso-spec-orchestrator/references/spec-driven-flow.md](../af-nso-spec-orchestrator/references/spec-driven-flow.md).

## Generic Input Interpretation

- For spreadsheets, inspect sheet names, headings, row labels, merged-looking title areas, and populated cells to identify requirement facts. A spreadsheet may be row-oriented, column-oriented, matrix-style, or just contain pasted configuration.
- For Word/text documents, inspect headings, sections, tables, bullet lists, prose, and code/config blocks.
- For raw configuration, identify service clues from VRF names, interfaces, routing sections, comments, descriptions, device syntax, and surrounding user context.
- For command input, parse the requested service, device targets, preferences, and any explicit constraints.
- When the source supports multiple interpretations, ask the user which interpretation is correct.
- When non-variable facts are absent, leave them as `REPLACE_ME` in the skeleton and collect them with `aifirst collect` (step 7). Use the targeted questions in `clarification-checklist.md` only in the fallback path when the form collector is unavailable.

## References

- Required output shape: `template.md`
- End-to-end flow (author → register → build → archive): [af-nso-spec-orchestrator/references/spec-driven-flow.md](../af-nso-spec-orchestrator/references/spec-driven-flow.md)
- Missing-value collection (primary): `aifirst collect --spec <file>` — opens a browser form and writes submitted values back in place.
- Package-memory registration is owned by **af-nso-spec-orchestrator** (`aifirst spec change new` at build start) — this skill does not open a change.
- Fallback clarifying questions: `clarification-checklist.md`
- Working input location: `aifirstspec/inputs/<descriptive-name>.yaml` (the deliverable; the orchestrator registers it into the store at build time)
