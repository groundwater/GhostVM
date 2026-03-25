---
name: appcast
description: Sign DMG for Sparkle and update appcast.xml via PR. Use after a GitHub release is published.
user-invocable: true
---

# Appcast Update Workflow

Version: $ARGUMENTS

If no version is provided, ask the user what version to update the appcast for.

## 1. Pre-flight checks

1. **Clean working tree** — abort if `git status --porcelain` shows changes
2. **On main branch** — abort if not on `main`
3. **GitHub release exists** — verify `gh release view v<VERSION> -R groundwater/GhostVM` succeeds
4. **DMG available** — check if `GhostVM/build/dist/GhostVM-<VERSION>.dmg` exists locally. If not, download it:
   ```
   mkdir -p GhostVM/build/dist
   gh release download v<VERSION> -R groundwater/GhostVM --pattern "GhostVM-<VERSION>.dmg" --dir GhostVM/build/dist
   ```

## 2. Sign DMG for Sparkle

Run `make -C GhostVM sparkle-sign VERSION=<VERSION>`. Capture the `edSignature` and `length` values from the output.

## 3. Appcast PR (subtree)

Changes to `GhostVM/` must go through a PR on the upstream repo.

1. Update `GhostVM/Website/public/appcast.xml` — add a new `<item>` entry **above** existing items (newest first):
   ```xml
   <item>
     <title>GhostVM <VERSION></title>
     <pubDate>DATE_RFC2822</pubDate>
     <sparkle:version><VERSION></sparkle:version>
     <sparkle:shortVersionString><VERSION></sparkle:shortVersionString>
     <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
     <description><![CDATA[<ul><li>Changes from release notes</li></ul>]]></description>
     <enclosure
       url="https://github.com/groundwater/GhostVM/releases/download/v<VERSION>/GhostVM-<VERSION>.dmg"
       type="application/octet-stream"
       sparkle:edSignature="FROM_SIGN_UPDATE"
       length="DMG_SIZE_BYTES"
     />
   </item>
   ```
   - Replace `FROM_SIGN_UPDATE` and `DMG_SIZE_BYTES` with the values from `make -C GhostVM sparkle-sign`
   - Use `date -R` for `DATE_RFC2822`
   - Get release notes from `gh release view v<VERSION> -R groundwater/GhostVM --json body -q .body` and summarize into `<li>` items
2. Commit locally: `git add GhostVM/Website/public/appcast.xml && git commit -m "Update appcast for v<VERSION>"`
3. Push subtree to upstream branch: `git subtree push --prefix=GhostVM ghostvm appcast/v<VERSION>`
4. Create PR on upstream: `gh pr create -R groundwater/GhostVM --head appcast/v<VERSION> --title "Update appcast for v<VERSION>" --body "Add Sparkle update feed entry for v<VERSION>."`
5. Merge (squash): `gh pr merge -R groundwater/GhostVM --squash --auto`
6. Wait for merge, then pull back: `git subtree pull --prefix=GhostVM ghostvm main --squash`
7. Push dev repo: `git push`

## 4. Post-update

1. Report that the appcast has been updated
2. Tell the user GitHub Pages will auto-deploy the updated feed
