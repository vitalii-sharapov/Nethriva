#!/bin/bash
set -euo pipefail
app="${1:?Usage: verify-distribution.sh /path/to/Nethriva.app}"
[[ -d "$app/Contents" ]] || exit 1
codesign --verify --deep --strict "$app"
metadata="$(codesign -d --verbose=4 "$app" 2>&1)"
grep -q 'Authority=Developer ID Application:' <<< "$metadata" || { echo 'Distribution blocked: Developer ID Application signing is required.' >&2; exit 1; }
grep -q 'runtime' <<< "$metadata" || { echo 'Distribution blocked: Hardened Runtime is required.' >&2; exit 1; }
entitlements="$(codesign -d --entitlements :- "$app" 2>/dev/null)"
if grep -Eq 'disable-library-validation|allow-unsigned-executable-memory|disable-executable-page-protection|allow-dyld-environment-variables|get-task-allow' <<< "$entitlements"; then
  echo 'Distribution blocked: development runtime exceptions are present.' >&2; exit 1
fi
spctl --assess --type execute --verbose=4 "$app"
xcrun stapler validate "$app"
echo 'Distribution signing, runtime policy, Gatekeeper assessment and stapled notarization verified.'
