---
name: release
description: Version bump PR, build/notarize DMG, and create GitHub release. Use when the user wants to cut a release.
user-invocable: true
---

# Release Workflow

Release version: $ARGUMENTS

If no version is provided, ask the user what version to release.

## 1. Pre-flight checks

1. **Clean working tree** — abort if `git status --porcelain` shows changes
2. **On main branch** — abort if not on `main`
3. **Tests pass** — run `make -C GhostVM test` and abort on failure
4. **Notarization credentials** — verify `GhostVM/.env` has `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, and `NOTARY_PASSWORD` set (not commented out, not empty, no quotes around values). Makefile uses `include .env` which does NOT strip quotes — values must be bare.
5. **Signing identity** — verify `security find-identity -v -p codesigning | grep "Developer ID Application"` returns a match
6. **Tag doesn't exist** — abort if `git tag -l v<VERSION>` returns a match
7. **Versions in sync** — run `make -C GhostVM check-version` and abort on failure

## 2. Version bump (subtree PR)

Changes to `GhostVM/` must go through a PR on the upstream repo.

1. Bump versions: `make -C GhostVM bump VERSION=<VERSION>`
2. Commit locally: `git add GhostVM/macOS/ && git commit -m "Bump version to <VERSION>"`
3. Push subtree to upstream branch: `git subtree push --prefix=GhostVM ghostvm release/v<VERSION>`
4. Create PR on upstream: `gh pr create -R groundwater/GhostVM --head release/v<VERSION> --title "Release v<VERSION>" --body "Bump all targets to <VERSION> for release."`

**Do NOT merge yet** — build the DMG first to catch failures before burning a tag.

## 3. Build notarized DMG

Run `make -C GhostVM dist VERSION=<VERSION>`. This:
- Builds the app, CLI, and GhostTools
- Signs everything with Developer ID
- Creates the DMG
- Submits to Apple notary service and staples the ticket

Verify the output says `status: Accepted` and `The staple and validate action worked!`.

If the build or notarization fails, fix the issue, commit, re-push the subtree, and retry `make -C GhostVM dist`. Only proceed once the DMG is notarized.

## 4. Merge and tag

1. Merge upstream PR (squash): `gh pr merge -R groundwater/GhostVM --squash --auto`
2. Wait for merge, then pull back: `git subtree pull --prefix=GhostVM ghostvm main --squash`
3. Push dev repo: `git push`
4. Create tag on the merge commit: `git tag v<VERSION>`
5. Push tag to upstream: `git push ghostvm v<VERSION>`

## 5. GitHub release

Determine the previous release tag for changelog generation, then create the release with the DMG attached in a single command (avoids GitHub's immutable-release lock-out):

```
gh release create v<VERSION> GhostVM/build/dist/GhostVM-<VERSION>.dmg \
  -R groundwater/GhostVM \
  --title "v<VERSION>" --target main \
  --notes "$(gh api repos/groundwater/GhostVM/releases/generate-notes \
    -f tag_name=v<VERSION> -f previous_tag_name=v<PREV_VERSION> --jq .body)"
```

## 6. Post-release

1. Report the release URL to the user
2. Tell the user to run `/appcast <VERSION>` when ready to publish the Sparkle update feed
