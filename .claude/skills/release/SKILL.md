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
3. **Tests pass** — run `make test` and abort on failure
4. **Notarization credentials** — verify `.env` has `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, and `NOTARY_PASSWORD` set (not commented out, not empty, no quotes around values). Makefile uses `include .env` which does NOT strip quotes — values must be bare.
5. **Signing identity** — verify `security find-identity -v -p codesigning | grep "Developer ID Application"` returns a match
6. **Tag doesn't exist** — abort if `git tag -l v<VERSION>` returns a match
7. **Versions in sync** — run `make check-version` and abort on failure

## 2. Version bump (local branch)

1. Create branch: `git checkout -b release/v<VERSION>`
2. Bump versions: `make bump VERSION=<VERSION>`
3. Commit: `git add macOS/ && git commit -m "Bump version to <VERSION>"`
4. Push: `git push -u origin release/v<VERSION>`
5. Create PR: `gh pr create --title "Release v<VERSION>" --body "Bump all targets to <VERSION> for release."`

**Do NOT merge yet** — build the DMG first to catch failures before burning a tag.

## 3. Build notarized DMG

Run `make dist VERSION=<VERSION>` **from the release branch**. This:
- Builds the app, CLI, and GhostTools
- Signs everything with Developer ID
- Creates the DMG
- Submits to Apple notary service and staples the ticket

Verify the output says `status: Accepted` and `The staple and validate action worked!`.

If the build or notarization fails, fix the issue on the release branch, amend or add a commit, force-push, and retry `make dist`. Only proceed once the DMG is notarized.

## 4. Merge and tag

1. Merge (squash): `gh pr merge --squash --auto`
2. Wait for merge, then: `git checkout main && git pull`
3. Create tag on the merge commit: `git tag v<VERSION>`
4. Push tag: `git push origin v<VERSION>`

## 5. GitHub release

Determine the previous release tag for changelog generation, then create the release with the DMG attached in a single command (avoids GitHub's immutable-release lock-out):

```
gh release create v<VERSION> build/dist/GhostVM-<VERSION>.dmg \
  --title "v<VERSION>" --target main \
  --notes "$(gh api repos/{owner}/{repo}/releases/generate-notes \
    -f tag_name=v<VERSION> -f previous_tag_name=v<PREV_VERSION> --jq .body)"
```

## 6. Post-release

1. Report the release URL to the user
2. Tell the user to run `/appcast <VERSION>` when ready to publish the Sparkle update feed
