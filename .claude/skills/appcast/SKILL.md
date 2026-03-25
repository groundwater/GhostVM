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
3. **GitHub release exists** — verify `gh release view v<VERSION>` succeeds
4. **DMG available** — check if `build/dist/GhostVM-<VERSION>.dmg` exists locally. If not, download it:
   ```
   mkdir -p build/dist
   gh release download v<VERSION> --pattern "GhostVM-<VERSION>.dmg" --dir build/dist
   ```

## 2. Sign DMG for Sparkle

Run `make sparkle-sign VERSION=<VERSION>`. Capture the `edSignature` and `length` values from the output.

## 3. Appcast PR

1. Create branch: `git checkout -b appcast/v<VERSION>`
2. Update `Website/public/appcast.xml` — add a new `<item>` entry **above** existing items (newest first):
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
   - Replace `FROM_SIGN_UPDATE` and `DMG_SIZE_BYTES` with the values from `make sparkle-sign`
   - Use `date -R` for `DATE_RFC2822`
   - Get release notes from `gh release view v<VERSION> --json body -q .body` and summarize into `<li>` items
3. Commit: `git add Website/public/appcast.xml && git commit -m "Update appcast for v<VERSION>"`
4. Push: `git push -u origin appcast/v<VERSION>`
5. Create PR: `gh pr create --title "Update appcast for v<VERSION>" --body "Add Sparkle update feed entry for v<VERSION>."`
6. Merge (squash): `gh pr merge --squash --auto`
7. Wait for merge, then: `git checkout main && git pull`

## 4. Post-update

1. Report that the appcast has been updated
2. Tell the user GitHub Pages will auto-deploy the updated feed
