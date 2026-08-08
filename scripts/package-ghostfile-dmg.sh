#!/bin/zsh

set -euo pipefail

app_path=${1:-}
dmg_path=${2:-}
volume_name=${3:-GhostFile}
readme_path=${GHOSTFILE_DMG_README:-}
sign_identity=${GHOSTFILE_CODESIGN_ID:-}
expected_version=${GHOSTFILE_EXPECTED_VERSION:-}
expected_build=${GHOSTFILE_EXPECTED_BUILD:-}
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [[ -z "$app_path" || -z "$dmg_path" ]]; then
    print -u2 "usage: $0 APP_PATH DMG_PATH [VOLUME_NAME]"
    exit 64
fi
if [[ ! -d "$app_path" || "${app_path:t}" != "GhostFile.app" ]]; then
    print -u2 "GhostFile app not found: $app_path"
    exit 66
fi
if [[ "${dmg_path:e}" != "dmg" ]]; then
    print -u2 "DMG output must end in .dmg: $dmg_path"
    exit 64
fi
if [[ -z "$sign_identity" ]]; then
    sign_identity=$(/usr/bin/security find-identity -v -p codesigning \
        | /usr/bin/sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
        | /usr/bin/head -1)
fi
if [[ "$sign_identity" != "Developer ID Application:"* ]]; then
    print -u2 "GhostFile DMGs require a Developer ID Application identity, got: $sign_identity"
    exit 65
fi
if [[ -z "$sign_identity" ]]; then
    print -u2 "No Developer ID Application signing identity was found."
    exit 69
fi

app_path=${app_path:A}
dmg_path=${dmg_path:A}
mkdir -p "${dmg_path:h}"
work_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ghostfile-dmg.XXXXXX")
stage_dir="$work_dir/stage"
mount_dir="$work_dir/mount"
temporary_dmg="$work_dir/GhostFile.dmg"
mounted=0

cleanup() {
    if ((mounted)); then
        /usr/bin/pluginkit -r "$mount_dir/GhostFile.app/Contents/Extensions/GhostFileFS.appex" \
            >/dev/null 2>&1 || true
        "$lsregister" -u "$mount_dir/GhostFile.app" >/dev/null 2>&1 || true
        /usr/bin/hdiutil detach "$mount_dir" -quiet >/dev/null 2>&1 || true
    fi
    /bin/rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

print "Verifying exported GhostFile.app…"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
signature_details=$(/usr/bin/codesign --display --verbose=4 "$app_path" 2>&1)
if [[ "$signature_details" != *"Authority=Developer ID Application:"* ]]; then
    print -u2 "GhostFile.app is not Developer ID signed. Export it with DeveloperIDExportOptions.plist first."
    exit 65
fi
if [[ "$signature_details" != *"flags="*"runtime"* ]]; then
    print -u2 "GhostFile.app does not have the hardened runtime enabled."
    exit 65
fi
app_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")
app_build=$(/usr/bin/plutil -extract CFBundleVersion raw "$app_path/Contents/Info.plist")
extension_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw \
    "$app_path/Contents/Extensions/GhostFileFS.appex/Contents/Info.plist")
extension_build=$(/usr/bin/plutil -extract CFBundleVersion raw \
    "$app_path/Contents/Extensions/GhostFileFS.appex/Contents/Info.plist")
if [[ "$app_version" != "$extension_version" || "$app_build" != "$extension_build" ]]; then
    print -u2 "App/extension version mismatch: app=$app_version ($app_build), extension=$extension_version ($extension_build)"
    exit 65
fi
entitlements_path="$work_dir/GhostFileFS-entitlements.plist"
# Current codesign emits a diagnostic representation for `--entitlements -`.
# The legacy `:-` output selector still emits a plist that plutil can inspect.
/usr/bin/codesign --display --entitlements :- \
    "$app_path/Contents/Extensions/GhostFileFS.appex" \
    >"$entitlements_path" 2>/dev/null
fskit_entitlement=$(/usr/bin/plutil -extract 'com\.apple\.developer\.fskit\.fsmodule' raw \
    "$entitlements_path" 2>/dev/null || true)
if [[ "$fskit_entitlement" != "true" ]]; then
    print -u2 "The exported GhostFileFS extension is missing its FSKit entitlement."
    exit 65
fi
if [[ -n "$expected_version" && "$app_version" != "$expected_version" ]]; then
    print -u2 "Expected version $expected_version, found $app_version"
    exit 65
fi
if [[ -n "$expected_build" && "$app_build" != "$expected_build" ]]; then
    print -u2 "Expected build $expected_build, found $app_build"
    exit 65
fi

mkdir -p "$stage_dir" "$mount_dir"
/usr/bin/ditto "$app_path" "$stage_dir/GhostFile.app"
/bin/ln -s /Applications "$stage_dir/Applications"
if [[ -n "$readme_path" ]]; then
    if [[ ! -f "$readme_path" ]]; then
        print -u2 "DMG README not found: $readme_path"
        exit 66
    fi
    /usr/bin/ditto "$readme_path" "$stage_dir/README.txt"
fi

print "Creating compressed APFS disk image…"
/usr/bin/hdiutil create \
    -volname "$volume_name" \
    -srcfolder "$stage_dir" \
    -fs APFS \
    -format UDZO \
    -ov \
    "$temporary_dmg" >/dev/null

print "Signing disk image with $sign_identity…"
/usr/bin/codesign --force --timestamp --sign "$sign_identity" "$temporary_dmg"
/usr/bin/codesign --verify --verbose=2 "$temporary_dmg"
/usr/bin/hdiutil verify "$temporary_dmg" >/dev/null

print "Inspecting packaged app…"
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$temporary_dmg" >/dev/null
mounted=1
[[ -d "$mount_dir/GhostFile.app" ]]
[[ $(/usr/bin/readlink "$mount_dir/Applications") == "/Applications" ]]
/usr/bin/codesign --verify --deep --strict --verbose=2 "$mount_dir/GhostFile.app"
packaged_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw \
    "$mount_dir/GhostFile.app/Contents/Info.plist")
packaged_build=$(/usr/bin/plutil -extract CFBundleVersion raw \
    "$mount_dir/GhostFile.app/Contents/Info.plist")
[[ "$packaged_version" == "$app_version" && "$packaged_build" == "$app_build" ]]

/usr/bin/pluginkit -r "$mount_dir/GhostFile.app/Contents/Extensions/GhostFileFS.appex" \
    >/dev/null 2>&1 || true
"$lsregister" -u "$mount_dir/GhostFile.app" >/dev/null 2>&1 || true
/usr/bin/hdiutil detach "$mount_dir" -quiet
mounted=0

/bin/rm -f "$dmg_path"
/bin/mv "$temporary_dmg" "$dmg_path"
print "GhostFile DMG ready: $dmg_path"
print "version=$app_version build=$app_build"
