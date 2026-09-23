#!/usr/bin/env bash
# Delete e2e test resources (named *-e2e-<run>) older than SWEEP_MAX_AGE_MIN
# (default 120). Backstop for a run whose teardown never happened.
# DRY_RUN=1 lists without deleting.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/render/lib.sh
source "$ROOT/tests/render/lib.sh"

cutoff="$(date -u -d "-${SWEEP_MAX_AGE_MIN:-120} minutes" +%Y-%m-%dT%H:%M:%SZ)"
found=0
sweep() { # sweep <list-path> <jq-object-key> <delete-prefix>
  local rows
  rows="$(api GET "$1?limit=100" | jq -r --arg k "$2" --arg c "$cutoff" --arg re "$E2E_NAME_RE" \
    '.[][$k] | select((.name | test($re)) and .createdAt < $c) | .id + " " + .name')"
  while read -r id name; do
    [ -n "$id" ] || continue
    found=1
    if [ "${DRY_RUN:-}" = "1" ]; then log "would delete $name ($id)"; else
      api DELETE "$3/$id" >/dev/null && log "swept $name ($id)"
    fi
  done <<<"$rows"
}
sweep /services service /services
sweep /key-value keyValue /key-value
sweep /postgres postgres /postgres
[ "$found" = 1 ] || log "nothing to sweep (older than $cutoff)"
