#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
app="${1:?Usage: verify-packaged-app.sh /path/to/Nethriva.app [version]}"
expected_version="${2:-}"
app="${app:A}"
[[ -d "${app}" && "${app:t}" == Nethriva.app ]] || { print -u2 'Expected a Nethriva.app bundle.'; exit 1; }
plist="${app}/Contents/Info.plist"
version="$(plutil -extract CFBundleShortVersionString raw "${plist}")"
minimum="$(plutil -extract LSMinimumSystemVersion raw "${plist}")"
[[ -z "${expected_version}" || "${version}" == "${expected_version}" ]] || { print -u2 'Packaged version differs from the requested release.'; exit 1; }
[[ "${minimum}" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || { print -u2 'Invalid minimum macOS version.'; exit 1; }
[[ -x "${app}/Contents/MacOS/Nethriva" ]] || { print -u2 'Missing executable or executable permission.'; exit 1; }

# This must run on the extracted distribution, not only the build product.
codesign --verify --deep --strict --verbose=2 "${app}"
lipo -verify_arch arm64 "${app}/Contents/MacOS/Nethriva"
while IFS= read -r -d '' link; do
  [[ -e "${link}" && "${link:A}" == "${app}/"* ]] || { print -u2 'Broken or escaping bundle symlink.'; exit 1; }
done < <(find "${app}" -type l -print0)

runtime="${app}/Contents/Resources/FreeRDP"
/bin/zsh "${script_dir}/validate-rdp-runtime.sh" "${runtime}" arm64
if [[ -d "${runtime}/x86_64" ]]; then
  /bin/zsh "${script_dir}/validate-rdp-runtime.sh" "${runtime}/x86_64" x86_64
fi

count=0
while IFS= read -r -d '' binary; do
  file -b "${binary}" | grep -q 'Mach-O' || continue
  architecture=arm64
  [[ "${binary}" != "${runtime}/x86_64/"* ]] || architecture=x86_64
  lipo -verify_arch "${architecture}" "${binary}"
  if [[ "${architecture}" == arm64 ]]; then
    # A generic slice is required even when building on a newer M-series Mac.
    # The header alone does not prove that every instruction is M1-compatible.
    otool -arch arm64 -hv "${binary}" | awk '
      $1 == "MH_MAGIC_64" && $2 == "ARM64" && $3 == "ALL" { generic = 1 }
      END { exit !generic }
    ' || { print -u2 'A bundled binary lacks the generic ARM64_ALL CPU subtype.'; exit 1; }
  fi
  build_version="$(vtool -arch "${architecture}" -show-build "${binary}")"
  [[ "$(print -r -- "${build_version}" | awk '/platform/ { print $2 }')" == MACOS ]] || {
    print -u2 'A bundled binary targets a platform other than macOS.'; exit 1
  }
  required="$(print -r -- "${build_version}" | awk '/minos/ { print $2; exit }')"
  [[ "${required}" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || { print -u2 'Cannot determine a bundled binary minimum OS.'; exit 1; }
  if ! awk -v declared="${minimum}" -v needed="${required}" 'BEGIN {
    split(declared, d, "."); split(needed, n, ".");
    for (i = 1; i <= 3; i++) {
      if (n[i] + 0 > d[i] + 0) exit 1;
      if (n[i] + 0 < d[i] + 0) exit 0;
    }
  }'; then
    print -u2 "A bundled binary requires macOS ${required}, above the declared ${minimum}."; exit 1
  fi
  # Cover the application and future helpers as well as the separately checked
  # FreeRDP closure. A developer's installed libraries must not mask a bad app.
  while IFS= read -r dependency; do
    case "${dependency}" in
      /System/Library/*|/usr/lib/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
      *) print -u2 'A bundled binary has a nonportable dependency path.'; exit 1 ;;
    esac
  done < <(otool -arch "${architecture}" -L "${binary}" | tail -n +2 | awk '{print $1}')
  while IFS= read -r runpath; do
    case "${runpath}" in
      /System/Library/*|/usr/lib/*|@loader_path|@loader_path/*|@executable_path|@executable_path/*) ;;
      *) print -u2 'A bundled binary has a nonportable runtime search path.'; exit 1 ;;
    esac
  done < <(otool -arch "${architecture}" -l "${binary}" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }')
  count=$((count + 1))
done < <(find "${app}" -type f -print0)
((count > 1)) || { print -u2 'No bundled native runtime was verified.'; exit 1; }
print "Verified Nethriva ${version}: resource seal, executable permissions, symlinks, generic arm64 slices, macOS platform/deployment limits and portable load paths (${count} binaries; minimum macOS ${minimum})."
print 'This is not notarization, a first-launch test, or certification of every Mac/macOS version.'
