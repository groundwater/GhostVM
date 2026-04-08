# Journal Policy

Every agent run must add one entry under:

`Documents/Journal/YYYY/MM/DD/{title}.md`

Issue execution plans are separate artifacts and belong under:

`Documents/Plans/YYYY/MM/DD/{title}.md`

## Required Fields

- intent
- actions
- verification
- outcome
- next questions

## Naming Rule

- Use a short kebab-case title.
- Prefer one entry per run instead of appending unrelated work into an older file.
- Do not reuse a journal file as the plan for a different task.

## Template

- Use `Documents/Journal/README.md` for the canonical template.
- Use `Documents/Developer/Workflow.md` for the issue execution lifecycle.
- The `Next Questions` section is always present and may say `None.` when there are no unresolved items.
