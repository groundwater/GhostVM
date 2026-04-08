# GitHub Labels Policy

Labels applied to issues on [groundwater/GhostVM](https://github.com/groundwater/GhostVM).

Every issue MUST have exactly one **category** label and one **priority** label.

---

## Category Labels

Category describes what kind of issue this is.

| Label | Description | When to use |
|---|---|---|
| `new/feature` | Single PR-sized new feature | Functionality that does not exist yet and can land in one PR |
| `new/epic` | Large multi-part initiative | Requires multiple PRs; break into sub-issues tagged `new/feature` |
| `fix/crash` | Crashes or critical errors | App crashes, data loss, unrecoverable errors |
| `fix/feature` | Obviously incomplete feature | Feature exists but is clearly broken or missing expected behavior |
| `fix/nit` | Minor nitpick or polish | Cosmetic issues, typos, small UX improvements |
| `support/discussion` | Open-ended discussion | Questions, brainstorming, no clear action yet |
| `support/request` | Bug or feature request | External user report that needs triage into a category above |
| `support/help` | App help | User needs assistance using the app |

### Triage flow for `support/*` labels

1. New external reports start as `support/request`.
2. Once understood, re-label to the appropriate `new/*` or `fix/*` category.
3. `support/discussion` stays until a concrete action is identified.
4. `support/help` is resolved directly and closed.

---

## Priority Labels

Priority describes when the issue should be tackled.

| Label | Description | Guideline |
|---|---|---|
| `prio/P1` | High priority | Work on next; blocks a release or affects many users |
| `prio/P2` | Medium priority | Should be done soon; important but not blocking |
| `prio/P3` | Lower priority | Nice to have; pick up when higher-priority work is clear |

### Priority rules

- `fix/crash` issues MUST be `prio/P1`.
- `support/*` issues do not require a priority label until triaged into a `new/*` or `fix/*` category.

---

## Other Labels

| Label | Description |
|---|---|
| `codex` | Suitable for Codex automated work |
