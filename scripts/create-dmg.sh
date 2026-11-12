#!/bin/zsh
set -euo pipefail

app_path="${1:?Usage: create-dmg.sh /path/to/Nethriva.app /path/to/Nethriva.dmg}"
dmg_path="${2:?Usage: create-dmg.sh /path/to/Nethriva.app /path/to/Nethriva.dmg}"
script_dir="${0:A:h}"
dmg_path="${dmg_path:a}"
for candidate in "${dmg_path}" "${dmg_path}.sha256"; do
  [[ ! -e "${candidate}" && ! -L "${candidate}" ]] || { print -u2 'DMG output exists; choose a new filename.'; exit 1; }
done
/bin/zsh "${script_dir}/verify-packaged-app.sh" "${app_path}"
staging_dir="$(mktemp -d /private/tmp/Nethriva-dmg-stage.XXXXXXXX)"
mount_dir="$(mktemp -d /private/tmp/Nethriva-dmg-mount.XXXXXXXX)"
mounted=false

cleanup() {
  if [[ "${mounted}" == true ]]; then hdiutil detach "${mount_dir}" >/dev/null || return 1; fi
  if [[ "${staging_dir}" == /private/tmp/Nethriva-dmg-stage.* && -d "${staging_dir}" ]]; then rm -rf -- "${staging_dir}"; fi
  if [[ "${mount_dir}" == /private/tmp/Nethriva-dmg-mount.* && -d "${mount_dir}" ]]; then rmdir "${mount_dir}"; fi
}
trap cleanup EXIT

ditto "${app_path}" "${staging_dir}/Nethriva.app"
/bin/zsh "${script_dir}/verify-packaged-app.sh" "${staging_dir}/Nethriva.app"
ln -s /Applications "${staging_dir}/Applications"
mkdir -p "${dmg_path:h}"
hdiutil create \
  -volname Nethriva \
  -srcfolder "${staging_dir}" \
  -format UDZO \
  "${dmg_path}"
hdiutil verify "${dmg_path}"
hdiutil attach -readonly -nobrowse -mountpoint "${mount_dir}" "${dmg_path}" >/dev/null
mounted=true
/bin/zsh "${script_dir}/verify-packaged-app.sh" "${mount_dir}/Nethriva.app"
hdiutil detach "${mount_dir}" >/dev/null
mounted=false
(cd "${dmg_path:h}" && shasum -a 256 "${dmg_path:t}") > "${dmg_path}.sha256"
