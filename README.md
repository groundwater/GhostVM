# GhostVM-dev

Development wrapper repo for [GhostVM](https://github.com/groundwater/GhostVM).

The `GhostVM/` directory is a [git subtree](https://www.atlassian.com/git/tutorials/git-subtree) tracking the upstream repo.

## Subtree Commands

```bash
# Pull latest from upstream
git subtree pull --prefix=GhostVM ghostvm main --squash

# Push changes back upstream
git subtree push --prefix=GhostVM ghostvm main
```
