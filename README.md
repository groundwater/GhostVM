# GhostVM-dev

Development wrapper repo for [GhostVM](https://github.com/groundwater/GhostVM).

The `GhostVM/` directory is a [git subtree](https://www.atlassian.com/git/tutorials/git-subtree) tracking the upstream repo.

## Workflow

- **Outer repo** — commit and push directly to `main`
- **Subtree (`GhostVM/`)** — changes go through PRs on the [upstream repo](https://github.com/groundwater/GhostVM)

### Subtree Changes

```bash
# Push subtree changes to a feature branch on upstream
git subtree push --prefix=GhostVM ghostvm my-feature-branch

# Open a PR on the upstream repo
gh pr create -R groundwater/GhostVM --head my-feature-branch --title "..." --body "..."

# After the PR merges, pull it back
git subtree pull --prefix=GhostVM ghostvm main --squash
```
