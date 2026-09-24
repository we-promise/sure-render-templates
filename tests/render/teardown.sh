#!/usr/bin/env bash
# Delete everything an e2e run created, then prove nothing with its suffix is
# left. Safe to run twice.
#   tests/render/teardown.sh <state.json> <suffix>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/render/lib.sh
source "$ROOT/tests/render/lib.sh"

STATE="$1"; SUFFIX="$2"
rc=0
del() { # del <path>
  if api DELETE "$1" >/dev/null 2>&1; then log "deleted $1"; else
    # 404 means already gone; anything else is reported by the leftover check.
    log "delete $1 failed or already gone"
  fi
}
if [ -f "$STATE" ]; then
  for id in $(jq -r '.services[]' "$STATE"); do del "/services/$id"; done
  for id in $(jq -r '.keyvalue[]' "$STATE"); do del "/key-value/$id"; done
  for id in $(jq -r '.postgres[]' "$STATE"); do del "/postgres/$id"; done
fi

# Leftover check by name, independent of the state file.
sleep 5
# Each list call must succeed; a failed call must not read as "nothing left".
names=""
for pair in services:service postgres:postgres key-value:keyValue; do
  path="${pair%%:*}"; key="${pair##*:}"
  out="$(api GET "/${path}?limit=100")" || { log "could not list /$path to verify teardown"; rc=1; continue; }
  names+="$(jq -r --arg k "$key" '.[][$k].name' <<<"$out")"$'\n'
done
left="$(grep -E -- "-${SUFFIX}\$" <<<"$names" || true)"
if [ -n "$left" ]; then
  log "LEFTOVER resources with suffix $SUFFIX (still billing!): $left"
  rc=1
elif [ "$rc" = 0 ]; then
  log "teardown verified: nothing named *-$SUFFIX remains"
  rm -f "$STATE"
fi
exit "$rc"
