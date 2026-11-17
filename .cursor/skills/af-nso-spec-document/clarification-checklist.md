# Clarification Checklist

> **Fallback only.** The primary way to collect missing non-variable fields is the
> interactive form via `aifirst collect --spec <file>` (see `SKILL.md` step 7). Use
> the questions below only when the form collector is unavailable (not installed, no
> browser, or the user cancelled).

Ask for any required field that is missing or ambiguous. Do not ask for fields already present in the input.

**Never ask about any field whose source value is a `<VARIABLE_NAME>` token.** These are intentional per-instance parameters and are resolved automatically into the `instance_variables:` block of the relevant service variant. Treat them as known values, not missing ones.

## Project

- What should the `project_name` be?
- What `version` should be used? Default to `1.0.0` only if the user agrees.
- What short `description` should summarize the service or automation?

## Development Preferences

- Which NSO version should this target?
- Which NED type or types should be used, for example `cisco-iosxr`, `cisco-nx`, or another NED?
- Which package structure should be used? Default option: `standard-blueprint`.
- Which code pattern should be used, for example `python`, `java`, or another implementation style?

## Network Context

- Is the topology `Standalone` or `LSA`?

## Device Details

- What is the device role, for example `Core-Router`, `PE`, `CE`, or another role?
- What is the device vendor?
- What is the model of the device?
- What OS version does the device run?
- What is the management IP?

## NED Details

- What NED type applies to this device?
- What NED version should be used?

## Service Details

- What is the service name?
- Are the discovered service variants correct?
- For each variant, what should the subtype and description be?
- What deployment model should each variant use?
- Is connectivity `dynamic` or `static`?
- Which routing protocol is used?
- Is the service topology `full-mesh`, `hub-spoke`, or another topology?

## Raw Configuration

- Is a raw configuration block available for each service variant?
- If raw config is missing, should the spec include `REPLACE_ME` placeholders or should the user provide config first?
- If raw config contains encrypted password lines, ask the user to confirm whether to preserve those source lines or redact them.

## Suggested Question Format

Use one grouped question when several fields are missing:

```text
I can build the spec, but these fields are missing from the input:
- Device model
- Device OS version
- NSO version
- NED version

Please provide those values, or explicitly confirm which ones should stay as REPLACE_ME.
```

## Mandatory Resolution Rule

- `REPLACE_ME` is never a default. Every non-variable field must be resolved from either the source input or a direct answer from the user.
- A vague go-ahead ("go ahead", "proceed", "looks good") only authorizes generating the spec with the values gathered so far — it does **not** authorize leaving unanswered fields as `REPLACE_ME`. If a field still has no value, ask again specifically for that field before finalizing.
- Only write `REPLACE_ME` for a field after the user has been asked about that specific field and has explicitly said to leave it unresolved.
- Saving a skeleton that still contains `REPLACE_ME` is expected before running `aifirst collect` (that step resolves the placeholders in place). Outside that sanctioned save-then-collect step, do not finalize a spec while any non-variable field remains an unauthorized `REPLACE_ME`.
