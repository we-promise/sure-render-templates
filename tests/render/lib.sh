#!/usr/bin/env bash
# Shared Render API helpers. Needs RENDER_API_KEY, curl, jq.
# shellcheck disable=SC2034

RENDER_API="${RENDER_API:-https://api.render.com/v1}"
RENDER_REGION="${RENDER_REGION:-oregon}"

: "${RENDER_API_KEY:?RENDER_API_KEY is not set (repo secret RENDER_API_KEY)}"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# keyvalue_create_body OWNER REGION: read one plan resource from stdin.
keyvalue_create_body() {
  jq -c --arg o "$1" --arg r "$2" '
    {name, plan, ipAllowList, ownerId: $o, region: $r}
    + (if has("maxmemoryPolicy") then {maxmemoryPolicy} else {} end)'
}

# api METHOD PATH [JSON-BODY] -> prints the response body; fails on non-2xx.
api() {
  local method="$1" path="$2" body="${3:-}" out code
  out="$(mktemp)"
  if [ -n "$body" ]; then
    code="$(curl -sS -o "$out" -w '%{http_code}' -X "$method" "${RENDER_API}${path}" \
      -H "Authorization: Bearer ${RENDER_API_KEY}" -H 'Accept: application/json' \
      -H 'Content-Type: application/json' --data-binary "$body")"
  else
    code="$(curl -sS -o "$out" -w '%{http_code}' -X "$method" "${RENDER_API}${path}" \
      -H "Authorization: Bearer ${RENDER_API_KEY}" -H 'Accept: application/json')"
  fi
  if [[ "$code" != 2* ]]; then
    log "API $method $path -> HTTP $code: $(head -c 600 "$out")"
    rm -f "$out"
    return 1
  fi
  cat "$out"
  rm -f "$out"
}

# The workspace to create test resources in: RENDER_OWNER_ID if set, else the
# only workspace the key can see. Refuses to guess between several.
owner_id() {
  if [ -n "${RENDER_OWNER_ID:-}" ]; then echo "$RENDER_OWNER_ID"; return; fi
  local owners n
  owners="$(api GET '/owners?limit=100')" || return 1
  n="$(jq 'length' <<<"$owners")"
  [ "$n" -eq 1 ] || die "API key sees $n workspaces; set RENDER_OWNER_ID ($(jq -r 'map(.owner.name + "=" + .owner.id) | join(", ")' <<<"$owners"))"
  jq -r '.[0].owner.id' <<<"$owners"
}

# Test resources are named <blueprint-name>-e2e-<run>. The sweeper and the
# post-teardown check match on this.
E2E_NAME_RE='^(sure-[a-z0-9-]+|alphaclaw)-e2e-[a-z0-9]+$'

# dump_diagnostics <state.json> <owner-id>: best-effort evidence for a failed
# run, printed to the job log BEFORE teardown deletes the services (Render
# keeps no logs for deleted services). Never fails and never changes the
# run's outcome; each section says when its API call did not work.
dump_diagnostics() {
  local state="$1" owner="${2:-}" id out
  [ -f "$state" ] || { log "diagnostics: no state file"; return 0; }
  for id in $(jq -r '.services[]?' "$state"); do
    log "::group::diagnostics service $id: deploys"
    if out="$(api GET "/services/$id/deploys?limit=3" 2>&1)"; then
      jq -r '.[] | .deploy | "\(.createdAt) deploy \(.id) \(.status) trigger=\(.trigger // "?")"' <<<"$out" 2>/dev/null || echo "$out" | head -c 800
    else echo "unavailable: $out" | head -c 600; fi
    log "::endgroup::"
    log "::group::diagnostics service $id: events (restarts, OOM, crashes)"
    if out="$(api GET "/services/$id/events?limit=30" 2>&1)"; then
      jq -r '.[] | .event | "\(.timestamp) \(.type) \(.details | tostring | .[0:300])"' <<<"$out" 2>/dev/null || echo "$out" | head -c 800
    else echo "unavailable: $out" | head -c 600; fi
    log "::endgroup::"
    log "::group::diagnostics service $id: last 150 log lines"
    if [ -z "$owner" ]; then echo "unavailable: no owner id"
    elif out="$(api GET "/logs?ownerId=$owner&resource=$id&direction=backward&limit=150" 2>&1)"; then
      jq -r '.logs | reverse | .[] | "\(.timestamp) \(.message)"' <<<"$out" 2>/dev/null || echo "$out" | head -c 800
    else echo "unavailable: $out" | head -c 600; fi
    log "::endgroup::"
  done
  return 0
}
