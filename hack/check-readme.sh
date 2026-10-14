#!/usr/bin/env bash
# Fail when the README's chart table disagrees with charts/*/Chart.yaml.
#
# The table rows look like
#   | [`synapse`](charts/synapse) | 0.10.1 | 0.8.3 | ... |
# and each chart must appear once with its Chart.yaml version and appVersion.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readme="$root/README.md"
rc=0

for chartyaml in "$root"/charts/*/Chart.yaml; do
  [ -f "$chartyaml" ] || continue
  name=$(basename "$(dirname "$chartyaml")")
  version=$(awk '/^version:/{gsub(/["'\'']/, "", $2); print $2; exit}' "$chartyaml")
  app=$(awk '/^appVersion:/{gsub(/["'\'']/, "", $2); print $2; exit}' "$chartyaml")

  rows=$(grep -F "| [\`$name\`](charts/$name) |" "$readme" || true)
  if [ -z "$rows" ]; then
    echo "README.md: chart $name is missing from the chart table" >&2
    rc=1
    continue
  fi
  if [ "$(printf '%s\n' "$rows" | wc -l)" -ne 1 ]; then
    echo "README.md: chart $name appears more than once in the chart table" >&2
    rc=1
    continue
  fi

  rver=$(printf '%s\n' "$rows" | awk -F'|' '{gsub(/^ +| +$/, "", $3); print $3}')
  rapp=$(printf '%s\n' "$rows" | awk -F'|' '{gsub(/^ +| +$/, "", $4); print $4}')
  if [ "$rver" != "$version" ]; then
    echo "README.md: $name version is $rver, Chart.yaml says $version" >&2
    rc=1
  fi
  if [ "$rapp" != "$app" ]; then
    echo "README.md: $name appVersion is $rapp, Chart.yaml says $app" >&2
    rc=1
  fi
done

[ "$rc" -eq 0 ] && echo "README chart table matches charts/*/Chart.yaml"
exit "$rc"
