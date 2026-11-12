#!/bin/zsh
set -euo pipefail

# Package an existing signed export without rebuilding or altering its signature.
# This also repairs distribution packaging of a previous version independently
# from any unfinished changes in the current source checkout.
script_dir="${0:A:h}"
app="${1:?Usage: package-app.sh /path/to/Nethriva.app /path/to/output.zip [version]}"
output="${2:?Output ZIP is required}"
version="${3:-}"
output="${output:a}"
[[ "${output:e}" == zip ]] || { print -u2 'Output must be a ZIP.'; exit 1; }
for candidate in "${output}" "${output}.sha256"; do
  [[ ! -e "${candidate}" && ! -L "${candidate}" ]] || { print -u2 'Output exists; choose a new filename.'; exit 1; }
done
/bin/zsh "${script_dir}/verify-packaged-app.sh" "${app}" "${version}"
mkdir -p "${output:h}"
package_root="$(mktemp -d "${output:h}/.Nethriva-package.XXXXXXXX")"
cleanup() {
  if [[ "${package_root:t}" == .Nethriva-package.* && -d "${package_root}" ]]; then rm -rf -- "${package_root}"; fi
}
trap cleanup EXIT
ditto -c -k --sequesterRsrc --keepParent "${app}" "${package_root}/release.zip"
/bin/zsh "${script_dir}/verify-release-archive.sh" "${package_root}/release.zip" "${version}"
# Hard-link publication is atomic and refuses existing files, unlike overwrite.
ln "${package_root}/release.zip" "${output}"
(cd "${output:h}" && shasum -a 256 "${output:t}") > "${package_root}/checksum"
ln "${package_root}/checksum" "${output}.sha256"
print "Created verified package: ${output}"
print 'No upload, notarization or security-setting changes were performed.'
