#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
version="${1:-}"

if [[ -z "${version}" ]]; then
  version="$(xcodebuild -project "${repo_root}/Nethriva.xcodeproj" -scheme Nethriva -showBuildSettings |
    awk '/MARKETING_VERSION/ { print $3; exit }')"
fi

build_root="${repo_root}/.release-build"
output_root="${repo_root}/release-artifacts"
app_path="${build_root}/Build/Products/Release/Nethriva.app"
zip_path="${output_root}/Nethriva-${version}-macOS-arm64.zip"

rm -rf "${build_root}"
mkdir -p "${output_root}"

xcodebuild build \
  -project "${repo_root}/Nethriva.xcodeproj" \
  -scheme Nethriva \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${build_root}" \
  CODE_SIGNING_ALLOWED=NO

codesign --force --deep --sign - "${app_path}"
ditto -c -k --sequesterRsrc --keepParent "${app_path}" "${zip_path}"
shasum -a 256 "${zip_path}" > "${zip_path}.sha256"

"${script_dir}/create-dmg.sh" "${app_path}" "${output_root}/Nethriva-${version}-macOS-arm64.dmg"

echo "Release artifacts created in ${output_root}"
