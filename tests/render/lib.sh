#!/usr/bin/env bash
# Shared Render API helpers. Needs RENDER_API_KEY, curl, jq.
# shellcheck disable=SC2034

RENDER_API="${RENDER_API:-https://api.render.com/v1}"
RENDER_REGION="${RENDER_REGION:-oregon}"

: "${RENDER_API_KEY:?RENDER_API_KEY is not set (repo secret RENDER_API_KEY)}"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

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
E2E_NAME_RE='-e2e-[a-z0-9]+$'
