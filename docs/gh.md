GitHub CLI (gh) — Practical Reference

Purpose
- Fast, reliable workflows for issues/PRs from the terminal.
- Emphasis on clarity, reproducibility, and CI-friendly commands.

Setup
- Authenticate once: `gh auth login` (HTTPS, device flow is fine).
- Default repo to avoid repeating `--repo`: `gh repo set-default groundwater/book-editor`.
- Use real newlines in `--body` (no literal `\n`). Prefer heredocs.

Conventions
- Always specify the target repo explicitly (or set default): `--repo groundwater/book-editor`.
- Scriptable outputs: prefer `--json` with `-q` for `jq` queries over parsing text.
- Use squash merges unless the repo requires otherwise.
- Keep PR bodies actionable (summary, changes, verification, links to issues).

Issues

View
- When/Why: Inspect status or fetch fields for scripts.
- Example:
  `gh issue view 180 --repo groundwater/book-editor --json number,title,state,labels,assignees,url`

Edit (labels/body/title)
- When/Why: Triage or update acceptance criteria/checklists.
- Example (add label):
  `gh issue edit 180 --repo groundwater/book-editor --add-label codex`
- Example (replace body via heredoc):
  `gh issue edit 180 --repo groundwater/book-editor --body "$(cat ./tmp/issue-180.md)"`

Comment
- When/Why: Minimal status updates or linking related PRs.
- Example:
  `gh issue comment 180 --repo groundwater/book-editor --body "All acceptance criteria completed. Opened PR #196."`

List/Search
- When/Why: Filter by state/label/assignee quickly.
- Example:
  `gh issue list --repo groundwater/book-editor --label fix/refactor --state open --limit 50`

Pull Requests

Create
- When/Why: Open a PR with clear metadata from a feature branch.
- Example (heredoc for body):
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

Checks
- When/Why: Verify CI status; wait in scripts before merge.
- Examples:
  - Quick status: `gh pr checks 196 --repo groundwater/book-editor`
  - Watch until done: `gh pr checks 196 --repo groundwater/book-editor --watch`

Review
- When/Why: Move from draft, request reviews, or approve.
- Examples:
  - Ready for review: `gh pr ready 196 --repo groundwater/book-editor`
  - Request reviewers: `gh pr edit 196 --repo groundwater/book-editor --add-reviewer groundwater`
  - Approve: `gh pr review 196 --repo groundwater/book-editor --approve --body "LGTM"`

Merge
- When/Why: Prefer squash; auto-merge when checks pass.
- Examples:
  - Squash, delete branch, auto-merge: 
    `gh pr merge 196 --repo groundwater/book-editor --squash --delete-branch --auto --body "Closes #180."`
  - Immediate squash (checks already green):
    `gh pr merge 196 --repo groundwater/book-editor --squash --delete-branch --body "..."`

List/Search PRs
- When/Why: Find your open work, drafts, or label-based queues.
- Examples:
  - Mine: `gh pr list --repo groundwater/book-editor --author @me --state open`
  - Drafts: `gh pr list --repo groundwater/book-editor --search "is:draft"`

JSON Output & jq
- When/Why: Robust automation; avoid brittle text parsing.
- Examples:
  - Issue body only: `gh issue view 180 --repo groundwater/book-editor --json body -q .body`
  - PR checks URLs: `gh pr checks 196 --repo groundwater/book-editor --json url,name,summary -q '.[] | [.name, .summary, .url] | @tsv'`

Heredoc Patterns
- When/Why: Multi-line bodies without escaping.
- Template:
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

Branching Tips (git + gh)
- Create and push feature branch before PR:
  ```bash
  git checkout -b feat/my-change
  git push -u origin feat/my-change
  gh pr create --head feat/my-change --base main --title "..." --body "..."
  ```

Workflows (optional)
- When/Why: Rerun CI or inspect failed jobs from CLI.
- Examples:
  - List runs: `gh run list --repo groundwater/book-editor --limit 10`
  - View a run: `gh run view <run_id> --repo groundwater/book-editor --log`
  - Rerun failed jobs: `gh run rerun <run_id> --repo groundwater/book-editor --failed`

Troubleshooting
- Merge strategy disallowed: switch to allowed one (e.g., `--squash`).
- Missing scopes: re-auth with `gh auth refresh -h github.com -s repo`.
- Newlines: avoid `\n` strings; use heredocs or files.

Quick Recipes
- Close an issue with note:
  ```bash
  gh issue close 180 --repo groundwater/book-editor --comment "Fixed via #196"
  ```
- Update issue checklist (fetch/transform/put):
  ```bash
  BODY=$(gh issue view 180 --repo groundwater/book-editor --json body -q .body | \
    sed 's/- \[ \] /- [x] /g')
  gh issue edit 180 --repo groundwater/book-editor --body "$BODY"
  ```

