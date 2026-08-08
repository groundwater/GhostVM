#!/bin/zsh

set -euo pipefail

dmg_path=${1:-}
timeout=${NOTARY_TIMEOUT:-45m}
profile=${NOTARY_KEYCHAIN_PROFILE:-}
keychain=${NOTARY_KEYCHAIN_PATH:-}
key_file=${NOTARY_KEY_FILE:-}
key_id=${NOTARY_KEY_ID:-}
issuer_id=${NOTARY_ISSUER_ID:-}
apple_id=${NOTARY_APPLE_ID:-}
team_id=${NOTARY_TEAM_ID:-}
password=${NOTARY_PASSWORD:-}
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [[ -z "$dmg_path" || ! -f "$dmg_path" || "${dmg_path:e}" != "dmg" ]]; then
    print -u2 "usage: $0 PATH_TO_SIGNED_DMG"
    exit 64
fi
dmg_path=${dmg_path:A}
result_path="${dmg_path:r}.notary-result.json"
log_path="${dmg_path:r}.notary-log.json"

typeset -a auth_args
if [[ -n "$profile" ]]; then
    auth_args=(--keychain-profile "$profile")
    [[ -n "$keychain" ]] && auth_args+=(--keychain "$keychain")
elif [[ -n "$key_file" && -n "$key_id" ]]; then
    auth_args=(--key "$key_file" --key-id "$key_id")
    [[ -n "$issuer_id" ]] && auth_args+=(--issuer "$issuer_id")
elif [[ -n "$apple_id" && -n "$team_id" && -n "$password" ]]; then
    auth_args=(--apple-id "$apple_id" --team-id "$team_id" --password "$password")
else
    print -u2 "No notarization credentials configured."
    print -u2 "Set NOTARY_KEYCHAIN_PROFILE; NOTARY_KEY_FILE + NOTARY_KEY_ID; or"
    print -u2 "NOTARY_APPLE_ID + NOTARY_TEAM_ID + NOTARY_PASSWORD."
    exit 78
fi

print "Verifying signed disk image before upload…"
/usr/bin/codesign --verify --verbose=2 "$dmg_path"
/usr/bin/hdiutil verify "$dmg_path" >/dev/null

print "Submitting ${dmg_path:t} to Apple’s notary service…"
submit_succeeded=1
if ! /usr/bin/xcrun notarytool submit "$dmg_path" \
    "${auth_args[@]}" \
    --wait \
    --timeout "$timeout" \
    --output-format json > "$result_path"; then
    submit_succeeded=0
fi

notary_status=$(/usr/bin/plutil -extract status raw "$result_path" 2>/dev/null || true)
submission_id=$(/usr/bin/plutil -extract id raw "$result_path" 2>/dev/null || true)
if (( ! submit_succeeded )) || [[ "$notary_status" != "Accepted" ]]; then
    print -u2 "Notarization failed with status: ${notary_status:-unknown}"
    if [[ -n "$submission_id" ]]; then
        /usr/bin/xcrun notarytool log "$submission_id" "$log_path" "${auth_args[@]}" || true
        print -u2 "Notary log: $log_path"
    fi
    exit 65
fi

print "Notarization accepted; stapling ticket…"
/usr/bin/xcrun stapler staple "$dmg_path"
/usr/bin/xcrun stapler validate "$dmg_path"
/usr/bin/codesign --verify --verbose=2 "$dmg_path"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"

work_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ghostfile-notary-check.XXXXXX")
mount_dir="$work_dir/mount"
mkdir "$mount_dir"
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

/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$dmg_path" >/dev/null
mounted=1
/usr/bin/codesign --verify --deep --strict --verbose=2 "$mount_dir/GhostFile.app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$mount_dir/GhostFile.app"
/usr/bin/pluginkit -r "$mount_dir/GhostFile.app/Contents/Extensions/GhostFileFS.appex" \
    >/dev/null 2>&1 || true
"$lsregister" -u "$mount_dir/GhostFile.app" >/dev/null 2>&1 || true
/usr/bin/hdiutil detach "$mount_dir" -quiet
mounted=0

print "Notarized GhostFile DMG ready: $dmg_path"
print "submission=$submission_id"
print "result=$result_path"
