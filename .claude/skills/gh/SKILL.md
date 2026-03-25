---
name: github-cli
description: Execute GitHub workflows using gh CLI for issues, PRs, reviews, and merges. Use when user requests GitHub operations, issue management, pull request workflows, CI checks, or repository automation.
---

# GitHub CLI (gh) — Practical Reference

Fast, reliable workflows for issues/PRs from the terminal with emphasis on clarity, reproducibility, and CI-friendly commands.

## Setup Commands

Authentication (run once):
```bash
gh auth login  # HTTPS, device flow recommended
```

Set default repo to avoid repeating `--repo`:
```bash
gh repo set-default groundwater/book-editor
```

## Core Principles

- Always specify target repo explicitly: `--repo groundwater/book-editor` (or set default)
- Use `--json` with `jq` for scriptable outputs over text parsing
- Use real newlines in `--body` (heredocs, not literal `\n`)
- Prefer squash merges unless repo requires otherwise
- Keep PR bodies actionable: summary, changes, verification, issue links

## Issue Operations

### View Issue
Inspect status or fetch fields for scripts:
```bash
gh issue view 180 --repo groundwater/book-editor --json number,title,state,labels,assignees,url
```

### Edit Issue
Add labels:
```bash
gh issue edit 180 --repo groundwater/book-editor --add-label codex
```

Replace body via heredoc:
```bash
gh issue edit 180 --repo groundwater/book-editor --body "$(cat ./tmp/issue-180.md)"
```

### Comment on Issue
Minimal status updates or linking PRs:
```bash
gh issue comment 180 --repo groundwater/book-editor --body "All acceptance criteria completed. Opened PR #196."
```

### List/Search Issues
Filter by state/label/assignee:
```bash
gh issue list --repo groundwater/book-editor --label fix/refactor --state open --limit 50
```

### Close Issue
```bash
gh issue close 180 --repo groundwater/book-editor --comment "Fixed via #196"
```

## Pull Request Operations

### Create PR
Use heredoc for multi-line body:
```bash
gh pr create \
  --repo groundwater/book-editor \
  --head refactor/remove-remote-cursors-overlay-180 \
  --base main \
  --title "v2: Remove unused RemoteCursorsOverlay" \
  --body "$(cat <<'BODY'
Summary
Remove the old React-based overlay in favor of presenceOverlayPlugin.

Changes
- Delete src/v2/RemoteCursorsOverlay.tsx

Verification
- lint/tests/build/e2e all pass

Closes #180
BODY
)"
```

### Check CI Status
Quick status:
```bash
gh pr checks 196 --repo groundwater/book-editor
```

Watch until complete:
```bash
gh pr checks 196 --repo groundwater/book-editor --watch
```

### Review Operations
Mark ready for review:
```bash
gh pr ready 196 --repo groundwater/book-editor
```

Request reviewers:
```bash
gh pr edit 196 --repo groundwater/book-editor --add-reviewer groundwater
```

Approve PR:
```bash
gh pr review 196 --repo groundwater/book-editor --approve --body "LGTM"
```

### Merge PR
Squash merge with auto-delete branch (wait for checks):
```bash
gh pr merge 196 --repo groundwater/book-editor --squash --delete-branch --auto --body "Closes #180."
```

Immediate merge (checks already green):
```bash
gh pr merge 196 --repo groundwater/book-editor --squash --delete-branch --body "Closes #180."
```

### List PRs
Your open PRs:
```bash
gh pr list --repo groundwater/book-editor --author @me --state open
```

Draft PRs:
```bash
gh pr list --repo groundwater/book-editor --search "is:draft"
```

## JSON Output & jq Queries

Extract issue body only:
```bash
gh issue view 180 --repo groundwater/book-editor --json body -q .body
```

Extract PR check details:
```bash
gh pr checks 196 --repo groundwater/book-editor --json url,name,summary -q '.[] | [.name, .summary, .url] | @tsv'
```

## Heredoc Pattern Template

For multi-line bodies without escaping:
```bash
BODY=$(cat <<'MD'
Title

Summary
- One
- Two
MD
)
gh issue edit 123 --body "$BODY"
```

## Branching Workflow

Create feature branch before PR:
```bash
git checkout -b feat/my-change
git push -u origin feat/my-change
gh pr create --head feat/my-change --base main --title "..." --body "..."
```

## Workflow Operations

List recent workflow runs:
```bash
gh run list --repo groundwater/book-editor --limit 10
```

View run logs:
```bash
gh run view <run_id> --repo groundwater/book-editor --log
```

Rerun failed jobs:
```bash
gh run rerun <run_id> --repo groundwater/book-editor --failed
```

## Common Recipes

### Update Issue Checklist
Fetch, transform, and update:
```bash
BODY=$(gh issue view 180 --repo groundwater/book-editor --json body -q .body | \
  sed 's/- \[ \] /- [x] /g')
gh issue edit 180 --repo groundwater/book-editor --body "$BODY"
```

### Complete Issue → PR → Merge Workflow
```bash
# 1. Comment on issue
gh issue comment 180 --repo groundwater/book-editor --body "Working on this"

# 2. Create PR
gh pr create --repo groundwater/book-editor --head feat/fix-180 --base main --title "..." --body "Closes #180"

# 3. Wait for checks
gh pr checks 196 --repo groundwater/book-editor --watch

# 4. Merge
gh pr merge 196 --repo groundwater/book-editor --squash --delete-branch --body "Closes #180"
```

## Troubleshooting

**Merge strategy disallowed**: Switch to allowed strategy (e.g., `--squash`)

**Missing scopes**: Re-authenticate with proper permissions:
```bash
gh auth refresh -h github.com -s repo
```

**Newlines broken**: Avoid `\n` strings; use heredocs or files

## Best Practices

1. Use `--json` for automation instead of parsing text output
2. Set repo default once to avoid repetition
3. Heredocs for all multi-line content
4. Squash merge by default for clean history
5. Link issues in PR bodies with "Closes #N"
6. Wait for checks with `--watch` before merging
7. Use `--auto` flag to merge once checks pass
