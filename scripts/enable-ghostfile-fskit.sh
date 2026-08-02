#!/bin/zsh

set -euo pipefail

readonly app_path="${1:-/Applications/GhostFile.app}"
readonly extension_path="$app_path/Contents/Extensions/GhostFileFS.appex"
readonly settings_path="$HOME/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"
readonly lsregister_path="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ ! -d "$extension_path" ]]; then
    print -u2 "GhostFile FSKit extension not found at: $extension_path"
    exit 66
fi

readonly bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$extension_path/Contents/Info.plist")"
if [[ "$bundle_id" != "org.ghostvm.ghostfile.fs" ]]; then
    print -u2 "Unexpected FSKit bundle identifier: $bundle_id"
    exit 65
fi

echo "Verifying GhostFile signature…"
/usr/bin/codesign --verify --deep --strict "$app_path"

echo "Registering and selecting $bundle_id…"
"$lsregister_path" -f "$app_path"
/usr/bin/pluginkit -e use -i "$bundle_id"

if [[ ! -f "$settings_path" ]]; then
    /bin/mkdir -p "${settings_path:h}"
    /usr/libexec/PlistBuddy -c "Add : array" "$settings_path"
fi

if ! /usr/bin/plutil -p "$settings_path" | /usr/bin/grep -Fq "\"$bundle_id\""; then
    readonly module_count="$(/usr/bin/plutil -p "$settings_path" | /usr/bin/awk '/^[[:space:]]+[0-9]+ => / { count++ } END { print count + 0 }')"
    /usr/bin/plutil -insert "$module_count" -string "$bundle_id" "$settings_path"
fi

echo "Restarting the stale FSKit daemon (administrator password required)…"
/usr/bin/sudo /usr/bin/killall fskitd 2>/dev/null || true
/usr/bin/killall fskit_agent 2>/dev/null || true
/bin/sleep 2

echo
echo "FSKit registration:"
/usr/bin/pluginkit -v -m -A -D -p com.apple.fskit.fsmodule | /usr/bin/grep -F "$bundle_id" || true
echo
echo "Enabled module list:"
/usr/bin/plutil -p "$settings_path"
echo
echo "GhostFile FSKit recovery complete. Reopen GhostFile and switch to Mount."
