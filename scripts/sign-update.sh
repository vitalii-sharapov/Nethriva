#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
nethriva_developer_dir="$(xcode-select -p)"
if [[ ! -d "${nethriva_developer_dir}/Platforms/MacOSX.platform" ]]; then nethriva_developer_dir='/Applications/Xcode.app/Contents/Developer'; fi
nethriva_swift="${nethriva_developer_dir}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
nethriva_sdk="${nethriva_developer_dir}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
[[ -x "${nethriva_swift}" && -d "${nethriva_sdk}" ]] || { print -u2 'Full Xcode with the macOS SDK is required.'; exit 1; }
nethriva_arch="$(uname -m)"
[[ "${nethriva_arch}" == arm64 || "${nethriva_arch}" == x86_64 ]] || exit 1
exec "${nethriva_swift}" -sdk "${nethriva_sdk}" -target "${nethriva_arch}-apple-macosx14.0" "${script_dir}/sign-update.swift" "$@"
