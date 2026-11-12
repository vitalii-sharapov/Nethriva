#!/bin/bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
output="${1:?Usage: security-test.sh /absolute/private/results}"
[[ "$output" = /* ]] || { echo 'Use an absolute test output path.' >&2; exit 1; }
configuration="${NETHRIVA_TEST_CONFIGURATION:-Debug}"
[[ "$configuration" = Debug || "$configuration" = Release ]] || exit 1
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -x "$developer_dir/usr/bin/xcodebuild" ]] || { echo 'Full Xcode is required.' >&2; exit 1; }
[[ "$(uname -m)" = arm64 ]] || { echo 'The complete native security gate requires an Apple-silicon runner.' >&2; exit 1; }
mkdir -p -- "$output"
python3 "$script_dir/check-native-runtime.py" "$repo_root/Nethriva/Resources/FreeRDP"
package_cache="${NETHRIVA_PACKAGE_CACHE:-$output/Packages}"
DEVELOPER_DIR="$developer_dir" bash "$script_dir/prepare-swift-packages.sh" "$package_cache"
python3 -B -m unittest discover -s "$script_dir/tests" -p 'test_*.py'
args=(test -project "$repo_root/Nethriva.xcodeproj" -scheme Nethriva -configuration "$configuration"
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$output/DerivedData"
  -resultBundlePath "$output/Tests.xcresult" CODE_SIGNING_ALLOWED=NO)
args+=(-clonedSourcePackagesDirPath "$package_cache" -disableAutomaticPackageResolution -skipPackagePluginValidation)
if [[ "$configuration" = Release ]]; then
  # This single test explicitly requires DEBUG; every other test remains included.
  args+=(ENABLE_TESTABILITY=YES -skip-testing:NethrivaTests/NethrivaTests/testDebugBuildUsesAnIsolatedConnectionLibraryAndKeychainService)
fi
case "${NETHRIVA_ENABLE_ASAN:-NO}" in
  YES) args+=(-enableAddressSanitizer YES) ;;
  NO) ;;
  *) exit 1 ;;
esac
DEVELOPER_DIR="$developer_dir" "$developer_dir/usr/bin/xcodebuild" "${args[@]}"
python3 "$script_dir/security-ssh-fixture.py"
echo 'Full app/security tests and isolated SSH host-identity fixture passed.'
