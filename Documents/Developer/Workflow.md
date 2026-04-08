# Workflow

Canonical issue-to-closeout workflow for GhostVM-dev.

## Preflight

- Anchor paths from the repo root. The app/runtime subtree lives under `GhostVM/`.
- Reuse an existing plan or journal artifact when it already matches the task instead of creating a duplicate.

## Artifact Rules

- Plans are execution artifacts. Store them in `Documents/Plans/YYYY/MM/DD/{title}.md`.
- Prefer reusing or updating an existing plan over creating a duplicate.
- Journals are run logs. Store them in `Documents/Journal/YYYY/MM/DD/{title}.md`.
- Do not use journals as plan docs.

## Subtree Rules

- Changes to `GhostVM/` must go through a PR on `groundwater/GhostVM`.
- Use `git subtree push --prefix=GhostVM ghostvm <branch>` to push, then open a PR.
- After merge, pull back with `git subtree pull --prefix=GhostVM ghostvm main --squash`.
- Never push the subtree directly to `main`.

## Execution

- Give each Claude pass an explicit read scope, write scope, and acceptance criteria.
- Do not ask Claude for diffs or patches — perform the work directly in the workspace.
- Run targeted verification near the changed subsystem.
- For behavior-visible changes, verify through a real build (`make -C GhostVM debug`) not only unit tests.

## Closeout

- Keep commits scoped to the issue and its plan.
- Push to `groundwater/GhostVM-dev` before calling the work done.
- Close issues only after verification and merge state support the closeout.
