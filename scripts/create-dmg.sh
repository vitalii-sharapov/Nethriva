#!/bin/zsh
set -euo pipefail

app_path="${1:?Usage: create-dmg.sh /path/to/Nethriva.app /path/to/Nethriva.dmg}"
dmg_path="${2:?Usage: create-dmg.sh /path/to/Nethriva.app /path/to/Nethriva.dmg}"
staging_dir="$(mktemp -d)"

cleanup() {
  rm -rf "${staging_dir}"
}
trap cleanup EXIT

cp -R "${app_path}" "${staging_dir}/"
ln -s /Applications "${staging_dir}/Applications"
rm -f "${dmg_path}"
hdiutil create \
  -volname Nethriva \
  -srcfolder "${staging_dir}" \
  -ov \
  -format UDZO \
  "${dmg_path}"
shasum -a 256 "${dmg_path}" > "${dmg_path}.sha256"
