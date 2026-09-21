#!/usr/bin/env bash
# Validates every Grafana dashboard JSON under platform/observability/dashboards:
# parses, has a uid, uids are unique, every panel has a datasource and a title.
set -euo pipefail
cd "$(dirname "$0")/.."
dir=platform/observability/dashboards
shopt -s nullglob
files=("$dir"/*.json)
if [ ${#files[@]} -eq 0 ]; then echo "no dashboards yet"; exit 0; fi
uids=()
for f in "${files[@]}"; do
  jq -e . "$f" >/dev/null || { echo "invalid JSON: $f" >&2; exit 1; }
  uid=$(jq -r '.uid // empty' "$f")
  [ -n "$uid" ] || { echo "missing uid: $f" >&2; exit 1; }
  uids+=("$uid")
  missing=$(jq -r '[.panels[] | select(.type != "row") | select((.datasource // null) == null or (.title // "") == "") | .id] | length' "$f")
  [ "$missing" = "0" ] || { echo "$missing panel(s) without datasource or title: $f" >&2; exit 1; }
  echo "ok: $f ($uid)"
done
dupes=$(printf '%s\n' "${uids[@]}" | sort | uniq -d)
[ -z "$dupes" ] || { echo "duplicate uid(s): $dupes" >&2; exit 1; }
