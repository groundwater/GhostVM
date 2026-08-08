# Releasing GhostFile

GhostFile ships as a Developer ID signed, notarized, and stapled APFS disk
image. The disk image contains `GhostFile.app`, an `/Applications` shortcut,
and a short installation README.

## One-time setup

The release Mac needs:

- macOS 26 and Xcode 26.4 or newer;
- `xcodegen` (`brew install xcodegen`);
- Rust 1.88 or newer, unless the reusable GhostHTTP3 toolchain image is
  already available;
- a **Developer ID Application** certificate for the GhostFile team;
- permission and provisioning for the `com.apple.developer.fskit.fsmodule`
  entitlement.

The preferred notarization credential is a Keychain profile. This keeps the
Apple ID app-specific password out of shell history, process listings, and the
repository:

```sh
xcrun notarytool store-credentials ghostfile-notary \
  --apple-id you@example.com \
  --team-id YOUR_TEAM_ID
```

Enter the app-specific password at the secure prompt. Then add this to the
untracked `.env` file:

```sh
NOTARY_KEYCHAIN_PROFILE=ghostfile-notary
```

App Store Connect API keys are also supported for CI through
`NOTARY_KEY_FILE`, `NOTARY_KEY_ID`, and, for team keys,
`NOTARY_ISSUER_ID`. The older `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, and
`NOTARY_PASSWORD` combination remains supported as a fallback.

## Build a locally verifiable DMG

```sh
make ghostfile-dmg \
  GHOSTFILE_VERSION=1.0.0 \
  GHOSTFILE_BUILD_NUMBER=100
```

This archives GhostFile, exports it with Developer ID signing, verifies the
app and embedded FSKit extension, creates and signs the disk image, mounts it
read-only for inspection, and unregisters temporary FSKit copies. It does not
contact Apple's notary service and must not be distributed.

When no version or build number is supplied, the same timestamp is used for
both, yielding a naturally increasing build number. Explicit build numbers
must increase for each published version.

## Build the distributable artifact

```sh
make ghostfile-notarized-dmg \
  GHOSTFILE_VERSION=1.0.0 \
  GHOSTFILE_BUILD_NUMBER=100
```

The release target performs the local DMG build and then:

1. submits a separate, clearly named staging copy with `notarytool --wait`;
2. records the submission JSON next to the image;
3. retrieves the detailed Apple log if notarization is rejected;
4. staples and validates the accepted ticket;
5. checks the DMG and contained app with Gatekeeper;
6. copies the final DMG to `GHOSTFILE_SHARED_DOWNLOADS` when that directory
   exists.

Only distribute the resulting file named
`GhostFile-<version>-notarized-arm64.dmg`.

If submission fails, that final filename is never created. The rejected
`*-notary-submission-arm64.dmg` and Apple log remain available for diagnosis.

## Standalone helpers

The packaging and notarization stages can be rerun independently:

```sh
GHOSTFILE_CODESIGN_ID='Developer ID Application: Example (TEAMID)' \
GHOSTFILE_DMG_README=macOS/GhostFile/DMG_README.txt \
scripts/package-ghostfile-dmg.sh \
  /path/to/GhostFile.app \
  build/GhostFile-local-arm64.dmg

NOTARY_KEYCHAIN_PROFILE=ghostfile-notary \
scripts/notarize-ghostfile-dmg.sh \
  build/GhostFile-local-arm64.dmg
```

The packaging helper refuses development-signed apps, apps without hardened
runtime, mismatched app/extension versions, and extensions missing the FSKit
entitlement.

## CI secrets

A CI signing runner needs these secrets or their equivalent:

- the Developer ID Application certificate and its import password;
- a Developer ID provisioning profile covering `org.ghostvm.ghostfile.fs`;
- an App Store Connect API private key, key ID, and issuer ID;
- `GHOSTFILE_SIGNING_TEAM`.

Never commit certificates, provisioning profiles, API keys, app-specific
passwords, generated notarization JSON, or temporary keychains.
