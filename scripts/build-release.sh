#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
nethriva_developer_dir="$(xcode-select -p)"
if [[ ! -d "${nethriva_developer_dir}/Platforms/MacOSX.platform" ]]; then
  nethriva_developer_dir='/Applications/Xcode.app/Contents/Developer'
fi
nethriva_xcodebuild="${nethriva_developer_dir}/usr/bin/xcodebuild"
[[ -x "${nethriva_xcodebuild}" ]] || { print -u2 'Install full Xcode or select its developer directory. Command Line Tools alone cannot build this app.'; exit 1; }
version="${1:-}"
architecture="${2:-arm64}"

if [[ -z "${version}" ]]; then
  version="$("${nethriva_xcodebuild}" -project "${repo_root}/Nethriva.xcodeproj" -scheme Nethriva -showBuildSettings |
    awk '/MARKETING_VERSION/ { print $3; exit }')"
fi

if ! [[ "${version}" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 'Use a numeric version such as 0.13.0.'; exit 1
fi
case "${architecture}" in
  arm64) architectures='arm64' ;;
  universal) architectures='arm64 x86_64' ;;
  *) print -u2 'Supported package architectures: arm64 or universal.'; exit 1 ;;
esac
# An Intel application slice cannot load arm64 RDP libraries.
if [[ "${architecture}" == universal ]]; then
  intel_runtime="${NETHRIVA_INTEL_RDP_ROOT:-}"
  [[ "${intel_runtime}" == /* ]] || { print -u2 'Universal packaging requires NETHRIVA_INTEL_RDP_ROOT: a complete matching x86_64 FreeRDP bundle.'; exit 1; }
  /bin/zsh "${script_dir}/validate-rdp-runtime.sh" "${intel_runtime}" x86_64
fi
DEVELOPER_DIR="${nethriva_developer_dir}" python3 "${script_dir}/check-dependency-updates.py" --require-current-toolchain
/bin/zsh "${script_dir}/validate-rdp-runtime.sh" "${repo_root}/Nethriva/Resources/FreeRDP" arm64
output_root="${NETHRIVA_RELEASE_OUTPUT:-${repo_root}/release-artifacts}"
mkdir -p "${output_root}"
zip_path="${output_root}/Nethriva-${version}-macOS-${architecture}.zip"
dmg_path="${output_root}/Nethriva-${version}-macOS-${architecture}.dmg"
for candidate in "${zip_path}" "${zip_path}.sha256" "${dmg_path}" "${dmg_path}.sha256"; do
  [[ ! -e "${candidate}" ]] || { print -u2 'Release output exists. Choose a new output folder; previous releases will not be overwritten.'; exit 1; }
done
build_root="$(mktemp -d /private/tmp/Nethriva-release.XXXXXXXX)"
cleanup() {
  if [[ "${build_root}" == /private/tmp/Nethriva-release.* && -d "${build_root}" ]]; then rm -rf -- "${build_root}"; fi
}
trap cleanup EXIT
app_path="${build_root}/Build/Products/Release/Nethriva.app"
package_cache="${NETHRIVA_PACKAGE_CACHE:-${build_root}/Packages}"
DEVELOPER_DIR="${nethriva_developer_dir}" bash "${script_dir}/prepare-swift-packages.sh" "${package_cache}"
package_options=(-clonedSourcePackagesDirPath "${package_cache}" -disableAutomaticPackageResolution -skipPackagePluginValidation)

"${nethriva_xcodebuild}" build \
  -project "${repo_root}/Nethriva.xcodeproj" \
  -scheme Nethriva \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "${build_root}" \
  "${package_options[@]}" \
  ARCHS="${architectures}" ONLY_ACTIVE_ARCH=NO MARKETING_VERSION="${version}" \
  NETHRIVA_UPDATE_PUBLIC_KEY="${NETHRIVA_UPDATE_PUBLIC_KEY:-}" CODE_SIGNING_ALLOWED=NO

if [[ "${architecture}" == universal ]]; then
  for component in Frameworks MacOS ThirdPartyLicenses; do
    ditto "${intel_runtime}/${component}" "${app_path}/Contents/Resources/FreeRDP/x86_64/${component}"
  done
  lipo -verify_arch arm64 x86_64 "${app_path}/Contents/MacOS/Nethriva"
else
  lipo -verify_arch arm64 "${app_path}/Contents/MacOS/Nethriva"
fi

# This command produces an explicit development/test export. Keep Hardened Runtime
# while allowing its ad-hoc native libraries; Developer ID distribution uses the
# exception-free Release entitlements and must pass verify-distribution.sh.
codesign --force --deep --options runtime --entitlements "${repo_root}/Nethriva/Nethriva.entitlements" --sign - "${app_path}"
codesign --verify --deep --strict "${app_path}"
/bin/zsh "${script_dir}/package-app.sh" "${app_path}" "${zip_path}" "${version}"

"${script_dir}/create-dmg.sh" "${app_path}" "${dmg_path}"

echo "Release artifacts created in ${output_root}"
print 'Locally signed, not Apple-notarized. No upload or publication was performed.'
