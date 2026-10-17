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
    code="$(curl -sS --connect-timeout 10 --max-time 60 -o "$out" -w '%{http_code}' -X "$method" "${RENDER_API}${path}" \
      -H "Authorization: Bearer ${RENDER_API_KEY}" -H 'Accept: application/json' \
      -H 'Content-Type: application/json' --data-binary "$body")"
  else
    code="$(curl -sS --connect-timeout 10 --max-time 60 -o "$out" -w '%{http_code}' -X "$method" "${RENDER_API}${path}" \
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


# redact_secrets: scrub credentials before third-party log text enters the
# job log (connection strings, password/token query params).
redact_secrets() {
  sed -E 's#(postgres(ql)?|redis|https?)://[^/@[:space:]]+@#\1://***@#g; s/([?&](password|passwd|pwd|secret|token|api_key|apikey)=)[^ &]+/\1***/gi'
}

# dump_service_diagnostics <service-id> <owner-id>: deploys, events, logs.
dump_service_diagnostics() {
  local id="$1" owner="${2:-}" out
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
  log "::group::diagnostics service $id: last 100 log lines"
  if [ -z "$owner" ]; then echo "unavailable: no owner id"
  elif out="$(api GET "/logs?ownerId=$owner&resource=$id&direction=backward&limit=100" 2>&1)"; then
    jq -r '.logs | reverse | .[] | "\(.timestamp) \(.message)"' <<<"$out" 2>/dev/null | redact_secrets || echo "$out" | head -c 800
  else echo "unavailable: $out" | head -c 600; fi
  log "::endgroup::"
  log "::group::diagnostics service $id: 5xx request logs"
  if [ -z "$owner" ]; then echo "unavailable: no owner id"
  elif out="$(api GET "/logs?ownerId=$owner&resource=$id&type=request&statusCode=5*&direction=backward&limit=50" 2>&1)"; then
    jq -r '.logs | reverse | .[] | "\(.timestamp) \(.message)"' <<<"$out" 2>/dev/null | redact_secrets || echo "$out" | head -c 800
  else echo "unavailable: $out" | head -c 600; fi
  log "::endgroup::"
}

# deploy_failure_looks_transient <service-id> <owner-id>: true only when the
# failed deploy's recent logs show the observed startup-race signature: the
# datastore REFUSING or TIMING OUT connections during boot. PG::ConnectionBad
# alone does not qualify - auth and config faults raise it too, and those are
# persistent. Gates the single deploy retry so a genuine app fault stays red.
deploy_failure_looks_transient() {
  local sid="$1" owner="${2:-}" out matched
  [ -n "$owner" ] || return 1
  out="$(api GET "/logs?ownerId=$owner&resource=$sid&direction=backward&limit=100" 2>/dev/null)" || return 1
  matched="$(jq -r '.logs[]?.message' <<<"$out" 2>/dev/null | grep -iE 'connection refused|connection timed out|timeout expired' | head -3)" || true
  [ -n "$matched" ] || return 1
  # The qualifying evidence belongs in the job log itself: the later
  # preservation dump can fail (seen: Render logs API 503), and the matched
  # lines are the whole basis for the retry. Sanitized: these are app logs.
  log "$sid transient-looking failure evidence: $(tr '\n' ' ' <<<"$matched" | redact_secrets | cut -c1-300)"
}

# report_oom_events <state.json>: full-run OOM evidence for every created
# service, printed BEFORE teardown deletes it (Render keeps nothing for
# deleted services). Best-effort; never changes the run's outcome. This is
# what makes "no OOM this run" a queried fact instead of an absence of
# printed failures.
report_oom_events() {
  local state="$1" id out hits="" n=0
  [ -f "$state" ] || { log "OOM events sweep: no state file"; return 0; }
  for id in $(jq -r '.services[]?' "$state"); do
    n=$(( n + 1 ))
    if out="$(api GET "/services/$id/events?limit=30" 2>/dev/null)"; then
      hits="$hits$(jq -r '.[] | .event | select((.type // "") + " " + ((.details // {}) | tostring) | test("oom|out.of.memory|memory.exceeded"; "i")) | "\(.timestamp) \(.type) \(.details | tostring | .[0:200])"' <<<"$out" 2>/dev/null)"
    else
      log "OOM events sweep: $id events unavailable"
    fi
  done
  if [ -n "$hits" ]; then
    log "full-run OOM events sweep: $n service(s) queried, OOM events FOUND:"
    redact_secrets <<<"  ${hits//$'\n'/$'\n'  }"
  else
    log "full-run OOM events sweep: $n service(s) queried for the whole run, none found"
  fi
}

# dump_diagnostics <state.json> <owner-id>: best-effort evidence for a failed
# run, printed to the job log BEFORE teardown deletes the services (Render
# keeps no logs for deleted services). Never fails and never changes the
# run's outcome; each section says when its API call did not work.
dump_diagnostics() {
  local state="$1" owner="${2:-}" id out
  [ -f "$state" ] || { log "diagnostics: no state file"; return 0; }
  for id in $(jq -r '.services[]?' "$state"); do
    dump_service_diagnostics "$id" "$owner"
  done
  # One-off jobs (migrations, checks, demo data): status plus logs, which
  # disappear with the service at teardown.
  local pair sid jid
  for pair in $(jq -r '.jobs[]?' "$state"); do
    sid="${pair%%/*}"; jid="${pair##*/}"
    log "::group::diagnostics job $jid (on $sid)"
    if out="$(api GET "/services/$sid/jobs/$jid" 2>&1)"; then
      jq -r '"status=\(.status // "?") startedAt=\(.startedAt // "?") finishedAt=\(.finishedAt // "?")"' <<<"$out" 2>/dev/null || echo "$out" | head -c 800
    else echo "unavailable: $out" | head -c 600; fi
    if [ -z "$owner" ]; then echo "unavailable: no owner id"
    elif out="$(api GET "/logs?ownerId=$owner&resource=$jid&direction=backward&limit=100" 2>&1)"; then
      jq -r '.logs | reverse | .[] | "\(.timestamp) \(.message)"' <<<"$out" 2>/dev/null | redact_secrets || echo "$out" | head -c 800
    else echo "unavailable: $out" | head -c 600; fi
    log "::endgroup::"
  done
  return 0
}
