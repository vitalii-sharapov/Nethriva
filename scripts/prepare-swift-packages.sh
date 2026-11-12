#!/bin/bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
cache="${1:?Usage: prepare-swift-packages.sh /absolute/private/package-cache}"
[[ "$cache" = /* ]] || exit 1
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DEVELOPER_DIR="$developer_dir" GIT_TERMINAL_PROMPT=0 "$developer_dir/usr/bin/xcodebuild" \
  -resolvePackageDependencies -project "$repo_root/Nethriva.xcodeproj" -scheme Nethriva \
  -clonedSourcePackagesDirPath "$cache"
python3 "$script_dir/verify-package-plugins.py" --package-cache "$cache"
