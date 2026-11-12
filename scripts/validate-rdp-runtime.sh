#!/bin/zsh
set -euo pipefail
runtime="${1:?Usage: validate-rdp-runtime.sh /absolute/runtime arm64|x86_64}"
architecture="${2:?Architecture is required}"
[[ "${runtime}" == /* && -d "${runtime}/Frameworks" && -d "${runtime}/ThirdPartyLicenses" ]] || { print -u2 'Incomplete runtime layout or license directory.'; exit 1; }
[[ "${architecture}" == arm64 || "${architecture}" == x86_64 ]] || exit 1
[[ -f "${runtime}/Frameworks/libNethrivaRDP.dylib" && -x "${runtime}/MacOS/sdl-freerdp" ]] || { print -u2 'Missing bridge or SDL client.'; exit 1; }
[[ -s "${runtime}/ThirdPartyLicenses/FreeRDP-LICENSE" && -s "${runtime}/ThirdPartyLicenses/OpenSSL-LICENSE.txt" ]] || { print -u2 'Required FreeRDP/OpenSSL license texts are missing.'; exit 1; }
count=0
while IFS= read -r -d '' library; do
  [[ "${library:A}" == "${runtime:A}"/* ]] || { print -u2 'Runtime symlink escapes its root.'; exit 1; }
  if file -L -b "${library}" | grep -q 'Mach-O'; then
    lipo -verify_arch "${architecture}" "${library}"
    count=$((count + 1))
    install_name="$(otool -arch "${architecture}" -D "${library}" | sed -n '2p')"
    if otool -arch "${architecture}" -L "${library}" | tail -n +2 | awk '{print $1}' | grep -E '^(/opt/homebrew|/usr/local|/Users|/private/tmp|/tmp)/' >/dev/null; then
      print -u2 'Runtime has machine-local dependencies. Relocate all libraries before packaging.'; exit 1
    fi
    while IFS= read -r dependency; do
      [[ "${dependency}" == "${install_name}" ]] && continue
      case "${dependency}" in
        @rpath/*) resolved="${runtime}/Frameworks/${dependency#@rpath/}" ;;
        @loader_path/*) resolved="${library:h}/${dependency#@loader_path/}" ;;
        @executable_path/*) resolved="${runtime}/MacOS/${dependency#@executable_path/}" ;;
        /System/Library/*|/usr/lib/*) continue ;;
        *) print -u2 'Unsupported runtime dependency path.'; exit 1 ;;
      esac
      [[ -f "${resolved}" && "${resolved:A}" == "${runtime:A}"/* ]] || { print -u2 "Missing/escaping relative runtime dependency: ${dependency:t}"; exit 1; }
    done < <(otool -arch "${architecture}" -L "${library}" | tail -n +2 | awk '{print $1}')
  fi
done < <(find "${runtime}/Frameworks" "${runtime}/MacOS" \( -type f -o -type l \) -print0)
((count > 3)) || { print -u2 'Runtime is not complete.'; exit 1; }
exports="$(nm -arch "${architecture}" -gU "${runtime}/Frameworks/libNethrivaRDP.dylib")"
for symbol in ConfigureOpenSSL SetConfigPath VerifySystemCertificate CreateView GetView Start ConnectionState TakeSavedCredentials FreeCredentialString LastError Resize Focus Paste PasteFiles PasteFilesAtPoint Destroy; do
  print -r -- "${exports}" | awk '{print $NF}' | grep -Fxq "_NethrivaRDP${symbol}" || { print -u2 'A required bridge export is missing.'; exit 1; }
done
script_dir="${0:A:h}"
python3 "${script_dir}/check-native-runtime.py" "${runtime}"
print "Validated ${architecture} pinned native runtime, signatures, compatibility, loader paths and security exports. Live runtime testing is still required."
