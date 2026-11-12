#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
archive="${1:?Usage: verify-release-archive.sh /path/to/Nethriva.zip [version]}"
version="${2:-}"
[[ -f "${archive}" ]] || { print -u2 'Release ZIP not found.'; exit 1; }
audit_root="$(mktemp -d /private/tmp/Nethriva-archive-check.XXXXXXXX)"
cleanup() {
  if [[ "${audit_root}" == /private/tmp/Nethriva-archive-check.* && -d "${audit_root}" ]]; then rm -rf -- "${audit_root}"; fi
}
trap cleanup EXIT
ditto -x -k "${archive}" "${audit_root}"
/bin/zsh "${script_dir}/verify-packaged-app.sh" "${audit_root}/Nethriva.app" "${version}"
print 'Extracted release ZIP passed verification.'
