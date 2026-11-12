#!/bin/bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
output="${1:?Usage: security-scan.sh /absolute/private/results /absolute/security-tools}"
tools="${2:?Pinned security-tool directory is required}"
[[ "$output" = /* && "$tools" = /* ]] || { echo 'Use absolute output/tool paths.' >&2; exit 1; }
mkdir -p -- "$output"
umask 077
"$tools/gitleaks" version
"$tools/osv-scanner" --version
(cd "$repo_root" && "$tools/actionlint" -shellcheck= -pyflakes=)
# Redact findings before they reach a report or stdout; never suppress detector failures.
"$tools/gitleaks" dir "$repo_root" --config "$repo_root/.gitleaks.toml" --redact=100 \
  --no-banner --report-format json --report-path "$output/gitleaks-working-tree.json"
"$tools/gitleaks" git "$repo_root" --config "$repo_root/.gitleaks.toml" --redact=100 \
  --no-banner --report-format json --report-path "$output/gitleaks-history.json"
"$tools/osv-scanner" scan source \
  --lockfile "$repo_root/Nethriva.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
  --lockfile "$repo_root/Nethriva/Resources/FreeRDP/SBOM.cdx.json" \
  --all-packages --format json --output-file "$output/osv.json"
python3 "$script_dir/check-dependency-updates.py" --report "$output/dependency-currency.json"
echo 'Secret/dependency scans completed. Review coverage limits and native upstream advisories before release.'
