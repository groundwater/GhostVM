#!/bin/bash
# Verify that provisioning profile certificates match the signing identity.
# AMFI rejects apps where the profile cert doesn't match the signing cert,
# even when entitlements are correct.
#
# Usage: verify-profile-cert.sh "Developer ID Application: Name (TEAM)" [profile1.provisionprofile ...]

set -euo pipefail

SIGNING_ID="$1"
shift

# Get the SHA-1 fingerprint of the signing certificate from the keychain
SIGNING_SHA1=$(security find-certificate -c "$SIGNING_ID" -a -Z 2>/dev/null \
    | grep "^SHA-1" | head -1 | awk '{print $NF}')

if [ -z "$SIGNING_SHA1" ]; then
    echo "ERROR: Could not find certificate for '$SIGNING_ID' in keychain." >&2
    exit 1
fi

for PROFILE in "$@"; do
    if [ -z "$PROFILE" ] || [ ! -f "$PROFILE" ]; then
        continue
    fi

    # Extract DER-encoded certificates from the profile and compute SHA-1 hashes
    PROFILE_CERTS=$(security cms -D -i "$PROFILE" 2>/dev/null | \
        python3 -c "
import plistlib, sys, hashlib
data = sys.stdin.buffer.read()
start = data.find(b'<?xml')
if start < 0:
    sys.exit(0)
plist = plistlib.loads(data[start:])
for cert in plist.get('DeveloperCertificates', []):
    print(hashlib.sha1(cert).hexdigest().upper())
" 2>/dev/null)

    if echo "$PROFILE_CERTS" | grep -qi "$SIGNING_SHA1"; then
        echo "  Profile OK: $(basename "$PROFILE")"
    else
        echo "ERROR: Profile '$(basename "$PROFILE")' does not contain the signing certificate." >&2
        echo "  Signing identity SHA-1: $SIGNING_SHA1" >&2
        echo "  Profile certificate(s): $PROFILE_CERTS" >&2
        echo "  Regenerate the profile at developer.apple.com with the current Developer ID certificate." >&2
        exit 1
    fi
done
