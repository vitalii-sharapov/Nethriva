#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
source_app="${1:?Usage: test-release-packaging.sh /path/to/signed/Nethriva.app}"
fixture_root="$(mktemp -d /private/tmp/Nethriva-package-tests.XXXXXXXX)"
cleanup() {
  if [[ "${fixture_root}" == /private/tmp/Nethriva-package-tests.* && -d "${fixture_root}" ]]; then rm -rf -- "${fixture_root}"; fi
}
trap cleanup EXIT
expect_failure() {
  local label="$1"
  shift
  if "$@" > "${fixture_root}/rejected.log" 2>&1; then
    print -u2 "FAIL: ${label} was accepted."; exit 1
  fi
  print "PASS: ${label} rejected."
}

/bin/zsh "${script_dir}/package-app.sh" "${source_app}" "${fixture_root}/valid.zip"
print 'PASS: signed app survives ZIP round trip.'
expect_failure 'existing package overwrite' /bin/zsh "${script_dir}/package-app.sh" "${source_app}" "${fixture_root}/valid.zip"
expect_failure 'wrong release version' /bin/zsh "${script_dir}/verify-release-archive.sh" "${fixture_root}/valid.zip" '0.0.0'
ditto -x -k "${fixture_root}/valid.zip" "${fixture_root}/missing-permission"
chmod a-x "${fixture_root}/missing-permission/Nethriva.app/Contents/MacOS/Nethriva"
ditto -c -k --sequesterRsrc --keepParent "${fixture_root}/missing-permission/Nethriva.app" "${fixture_root}/missing-permission.zip"
expect_failure 'ZIP with lost executable permission' /bin/zsh "${script_dir}/verify-release-archive.sh" "${fixture_root}/missing-permission.zip"
ditto -x -k "${fixture_root}/valid.zip" "${fixture_root}/flattened"
app="${fixture_root}/flattened/Nethriva.app"
link="${app}/Contents/Resources/FreeRDP/Frameworks/libfreerdp3.3.dylib"
[[ -L "${link}" ]] || { print -u2 'The regression fixture needs the FreeRDP library symlink.'; exit 1; }
cp -L "${link}" "${fixture_root}/materialized.dylib"
mv -f "${fixture_root}/materialized.dylib" "${link}"
ditto -c -k --sequesterRsrc --keepParent "${app}" "${fixture_root}/flattened.zip"
expect_failure 'ZIP with flattened library symlink' /bin/zsh "${script_dir}/verify-release-archive.sh" "${fixture_root}/flattened.zip"
# Each fixture has a valid signature, so rejection must come from the native
# compatibility checks rather than the outer resource seal.
ditto "${source_app}" "${fixture_root}/incompatible/Nethriva.app"
app="${fixture_root}/incompatible/Nethriva.app"
mkdir -p "${app}/Contents/Frameworks"
probe="${app}/Contents/Frameworks/libCompatibilityProbe.dylib"
print 'int nethriva_compatibility_probe(void) { return 0; }' > "${fixture_root}/probe.c"
clang -dynamiclib -target arm64-apple-macos14.0 "${fixture_root}/probe.c" \
  -Wl,-install_name,@rpath/libCompatibilityProbe.dylib -o "${fixture_root}/generic.dylib"
cp "${fixture_root}/generic.dylib" "${probe}"
codesign --force --deep --sign - "${app}" >/dev/null 2>&1
/bin/zsh "${script_dir}/verify-packaged-app.sh" "${app}"
print 'PASS: signed generic arm64/macOS fixture accepted.'

vtool -set-build-version maccatalyst 14.0 27.0 -replace -output "${probe}" "${fixture_root}/generic.dylib"
codesign --force --deep --sign - "${app}" >/dev/null 2>&1
codesign --verify --deep --strict "${app}"
expect_failure 'signed non-macOS binary' /bin/zsh "${script_dir}/verify-packaged-app.sh" "${app}"

vtool -set-build-version macos 15.0 27.0 -replace -output "${probe}" "${fixture_root}/generic.dylib"
codesign --force --deep --sign - "${app}" >/dev/null 2>&1
codesign --verify --deep --strict "${app}"
expect_failure 'signed binary above declared macOS minimum' /bin/zsh "${script_dir}/verify-packaged-app.sh" "${app}"

cp "${fixture_root}/generic.dylib" "${probe}"
install_name_tool -add_rpath /opt/homebrew/lib "${probe}"
codesign --force --deep --sign - "${app}" >/dev/null 2>&1
codesign --verify --deep --strict "${app}"
expect_failure 'signed machine-local runtime search path' /bin/zsh "${script_dir}/verify-packaged-app.sh" "${app}"

clang -dynamiclib -target arm64e-apple-macos14.0 "${fixture_root}/probe.c" \
  -Wl,-install_name,@rpath/libCompatibilityProbe.dylib -o "${probe}"
codesign --force --deep --sign - "${app}" >/dev/null 2>&1
codesign --verify --deep --strict "${app}"
expect_failure 'signed restricted CPU subtype' /bin/zsh "${script_dir}/verify-packaged-app.sh" "${app}"
print 'All ten release packaging and compatibility regression checks passed.'
