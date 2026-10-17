#!/usr/bin/env bash
# Real-Render e2e for one deploy branch. COSTS MONEY while it runs.
#
# Creates the Blueprint's resources through the Render API (Render has no
# public API to instantiate a Blueprint), named <name>-e2e-<run>, at the
# explicit Blueprint plans or its paid 512 MB new-service default. Waits for the deploys to go live, runs the same smoke
# test as the local e2e against the real https URL, then deletes everything.
#
#   E2E_BRANCH        deploy branch (default sure-no-ai)
#   E2E_RUN           run id used in resource names (default: GITHUB_RUN_ID or a timestamp)
#   E2E_CONFIRM_COST  must be "yes": the caller has seen the cost estimate
#   E2E_PLAN_WEB / E2E_PLAN_WORKER  e2e-only plan override for that service
#     type (legacy API name, e.g. "standard" = 1c-2g); unset = 512 MB default.
#     One-off jobs inherit the web service's plan (render.com/docs/jobs).
#   E2E_KEEP=1        skip teardown (debugging only; the sweeper still deletes after 2h)
#   RENDER_API_KEY, optional RENDER_OWNER_ID / RENDER_REGION
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/render/lib.sh
source "$ROOT/tests/render/lib.sh"
# shellcheck source=tests/render/phases.sh
source "$ROOT/tests/render/phases.sh"

# Every phase below is required. The run is green only if all of them pass.
phase_expect "migrations applied" "new-user smoke" "Sidekiq worker registered" "demo data load" "demo-user smoke"

BRANCH="${E2E_BRANCH:-sure-no-ai}"
RUN="${E2E_RUN:-${GITHUB_RUN_ID:-$(date +%s)}}"
SUFFIX="e2e-$(tr '[:upper:]' '[:lower:]' <<<"$RUN" | tr -cd 'a-z0-9')"
STATE="${E2E_STATE:-$ROOT/tests/render/.state-$SUFFIX.json}"
DEPLOY_TIMEOUT="${E2E_DEPLOY_TIMEOUT:-1500}"

[ "${E2E_CONFIRM_COST:-}" = "yes" ] || die "refusing to create billable resources without E2E_CONFIRM_COST=yes"

work="$(mktemp -d)"
git -C "$ROOT" show "refs/remotes/origin/$BRANCH:render.yaml" > "$work/render.yaml"
python3 "$ROOT/tests/lib/blueprint.py" render-plan "$work/render.yaml" "$SUFFIX" > "$work/plan.json"
echo '{"postgres":[],"keyvalue":[],"services":[]}' > "$STATE"

remember() { # remember <kind> <id>
  local tmp; tmp="$(mktemp)"
  jq --arg k "$1" --arg id "$2" '.[$k] += [$id]' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
}

teardown() {
  local rc=$?
  phase_report || rc=1
  [ "$rc" -ne 0 ] || log "PASS $BRANCH on Render (all phases passed)"
  # Evidence first: the services (and their logs) vanish in the next step.
  if [ "$rc" -ne 0 ]; then dump_diagnostics "$STATE" "${owner:-}" || true; fi
  if [ "${E2E_KEEP:-}" = "1" ]; then
    log "E2E_KEEP=1: leaving resources up (state: $STATE)"
    exit "$rc"
  fi
  "$ROOT/tests/render/teardown.sh" "$STATE" "$SUFFIX" || rc=1
  rm -rf "$work"
  exit "$rc"
}
trap teardown EXIT

owner="$(owner_id)"
log "branch=$BRANCH suffix=$SUFFIX owner=$owner region=$RENDER_REGION"
# Cost line derived from the generated plan (render.com/pricing list rates,
# prorated per second while resources exist). Unknown plans are called out
# rather than silently priced at the 512 MB default; one-off jobs bill per
# second at the web service's plan rate on top.
rate_cents() { # rate_cents <kind> <api-plan|sizeGB> -> monthly cents or empty
  case "$1" in
    service) case "$2" in starter|0.5c-512mb) echo 700 ;; standard|1c-2g) echo 2500 ;; esac ;;
    kv)      case "$2" in starter|256mb) echo 1000 ;; esac ;;
    pg)      case "$2" in basic_1gb|0.5c-1g) echo 1900 ;; esac ;;
    disk)    echo $(( 25 * $2 )) ;;
  esac
}
total_cents=0; unknown_rate=0; cost_parts=""
while IFS=$'\t' read -r kind label plan; do
  cents="$(rate_cents "$kind" "$plan")"
  if [ -n "$cents" ]; then
    total_cents=$(( total_cents + cents ))
    cost_parts+="${cost_parts:+, }$label $plan \$$(awk "BEGIN{printf \"%.2f\", $cents/100}")"
  else
    unknown_rate=1
    cost_parts+="${cost_parts:+, }$label $plan (unpriced)"
  fi
done < <(jq -r '(.services[] | ["service", .blueprintName, .serviceDetails.plan] | @tsv),
               (.services[] | select(.serviceDetails.disk) | ["disk", .serviceDetails.disk.name, (.serviceDetails.disk.sizeGB | tostring)] | @tsv),
               (.keyvalues[] | ["kv", .blueprintName, .plan] | @tsv),
               (.databases[] | ["pg", .blueprintName, .plan] | @tsv)' "$work/plan.json")
log "cost while running: $cost_parts = \$$(awk "BEGIN{printf \"%.2f\", $total_cents/100}")/mo (~\$$(awk "BEGIN{printf \"%.3f\", $total_cents/72000}")/h), prorated per second, plus one-off jobs at the web plan rate$([ "$unknown_rate" = 1 ] && echo '; some plans unpriced - see render.com/pricing')"

# Datastores first; services need their connection strings.
pg_url=""; kv_url=""
while IFS= read -r row; do
  body="$(jq -c --arg o "$owner" --arg r "$RENDER_REGION" '{name, plan, version, databaseName, databaseUser, ownerId: $o, region: $r}' <<<"$row")"
  pg="$(api POST /postgres "$body")"; pg_id="$(jq -r '.id' <<<"$pg")"; remember postgres "$pg_id"
  log "created postgres $(jq -r .name <<<"$row") ($pg_id)"
done < <(jq -c '.databases[]' "$work/plan.json")
while IFS= read -r row; do
  body="$(keyvalue_create_body "$owner" "$RENDER_REGION" <<<"$row")"
  kv="$(api POST /key-value "$body")"; kv_id="$(jq -r '.id' <<<"$kv")"; remember keyvalue "$kv_id"
  log "created key value $(jq -r .name <<<"$row") ($kv_id)"
done < <(jq -c '.keyvalues[]' "$work/plan.json")

wait_available() { # wait_available <path>
  local deadline=$((SECONDS + 900)) st
  while :; do
    st="$(api GET "$1" | jq -r '.status')"
    [ "$st" = "available" ] && return 0
    (( SECONDS < deadline )) || die "$1 still '$st' after 15 min"
    sleep 10
  done
}
wait_available "/postgres/$pg_id"; log "postgres available"
wait_available "/key-value/$kv_id"; log "key value available"
pg_url="$(api GET "/postgres/$pg_id/connection-info" | jq -r '.internalConnectionString')"
kv_url="$(api GET "/key-value/$kv_id/connection-info" | jq -r '.internalConnectionString')"

declare -A deploy_of
web_url=""
while IFS= read -r row; do
  body="$(jq -c --arg o "$owner" --arg r "$RENDER_REGION" --arg db "$pg_url" --arg kv "$kv_url" '
    {type, name, ownerId: $o, autoDeploy,
     image: {ownerId: $o, imagePath},
     envVars: (.envVars | map(.value |= (if . == "@@DATABASE_URL@@" then $db elif . == "@@REDIS_URL@@" then $kv else . end))),
     serviceDetails: (.serviceDetails + {region: $r})}' <<<"$row")"
  resp="$(api POST /services "$body")"
  sid="$(jq -r '.service.id' <<<"$resp")"; remember services "$sid"
  deploy_of[$sid]="$(jq -r '.deployId // empty' <<<"$resp")"
  if [ "$(jq -r .type <<<"$row")" = "web_service" ]; then
    web_url="$(jq -r '.service.serviceDetails.url' <<<"$resp")"
    web_sid="$sid"
  fi
  log "created $(jq -r .type <<<"$row") $(jq -r .name <<<"$row") ($sid) plan=$(jq -r .serviceDetails.plan <<<"$row")"
done < <(jq -c '.services[]' "$work/plan.json")

# A first deploy can lose the new-datastore startup race (observed: Render's
# API said "available", the app then died in db:prepare with PG::ConnectionBad
# and the deploy ended update_failed). Retry ONCE, only when the failed
# service's own logs show that transient signature - a real app fault stays
# red. The retry is a redeploy of the SAME image/config (POST /deploys, no
# changes), its first failure's diagnostics are dumped BEFORE retrying, and
# the retry is announced so a green verdict is read with it.
for sid in "${!deploy_of[@]}"; do
  deadline=$((SECONDS + DEPLOY_TIMEOUT))
  retries=1
  while :; do
    did="${deploy_of[$sid]}"
    if [ -z "$did" ]; then
      did="$(api GET "/services/$sid/deploys?limit=1" | jq -r '.[0].deploy.id // empty')"
      deploy_of[$sid]="$did"
    fi
    st="$( [ -n "$did" ] && api GET "/services/$sid/deploys/$did" | jq -r '.status' || echo pending)"
    case "$st" in
      live) log "$sid live"; break ;;
      build_failed|update_failed|pre_deploy_failed)
        if (( retries > 0 )) && deploy_failure_looks_transient "$sid" "$owner"; then
          retries=$(( retries - 1 ))
          log "$sid deploy $did ended $st with a transient-looking startup failure; preserving its diagnostics before one retry of the SAME image/config"
          dump_service_diagnostics "$sid" "$owner" || true
          echo "::notice::$sid first deploy ended $st (transient-looking startup failure); retried once, unchanged image/config. This run's verdict includes one retry."
          sleep 90
          did="$(api POST "/services/$sid/deploys" '{}' | jq -r '.id // empty')"
          if [ -z "$did" ] || [ "$did" = null ]; then die "$sid could not restart a failed deploy"; fi
          deploy_of[$sid]="$did"
          log "$sid retry deploy $did started"
        else
          die "$sid deploy $did ended $st"
        fi ;;
      canceled|deactivated) die "$sid deploy $did ended $st" ;;
    esac
    (( SECONDS < deadline )) || die "$sid deploy still '$st' after ${DEPLOY_TIMEOUT}s"
    sleep 15
  done
done

[ -n "$web_url" ] || die "no web service URL"
# run_job <service-id> <label> <command> [timeout-s]: a Render one-off job on the
# service's image, env and plan (billed per second while it runs).
run_job() {
  local sid="$1" label="$2" cmd="$3" timeout="${4:-900}" jid st deadline errs=0
  jid="$(api POST "/services/$sid/jobs" "$(jq -nc --arg c "$cmd" '{startCommand: $c}')" | jq -r '.id')"
  if [ -z "$jid" ] || [ "$jid" = null ]; then log "ERROR: could not start job: $label"; return 1; fi
  remember jobs "$sid/$jid"
  log "job $label ($jid) started"
  deadline=$((SECONDS + timeout))
  while :; do
    if st="$(api GET "/services/$sid/jobs/$jid" 2>/dev/null | jq -r '.status')" && [ -n "$st" ] && [ "$st" != null ]; then
      errs=0
    else
      st=unknown
      errs=$((errs + 1))
      if (( errs >= 6 )); then log "ERROR: job $label status unreadable 6 times in a row"; return 1; fi
    fi
    case "$st" in
      succeeded) log "job $label succeeded"; return 0 ;;
      failed|canceled) log "ERROR: job $label ended $st (see the job's logs in the Render dashboard)"; return 1 ;;
    esac
    (( SECONDS < deadline )) || { api POST "/services/$sid/jobs/$jid/cancel" >/dev/null || true; log "ERROR: job $label still '$st' after ${timeout}s"; return 1; }
    sleep 10
  done
}

[ -n "${web_sid:-}" ] || die "no web service id"
# Phases. A failure does not stop phases that don't need it; a phase whose
# prerequisite did not pass is reported skipped, never passed.
phase_run "migrations applied" "" run_job "$web_sid" "migrations applied" \
  "bin/rails runner 'exit(ActiveRecord::Base.connection_pool.migration_context.needs_migration? ? 1 : 0)'"

# smoke.py reports its own sub-steps (it keeps going after a soft failure).
phase_run "new-user smoke" "migrations applied" python3 "$ROOT/tests/lib/smoke.py" "$web_url"

phase_run "Sidekiq worker registered" "migrations applied" run_job "$web_sid" "Sidekiq worker registered" \
  "bin/rails runner 'require \"sidekiq/api\"; exit(Sidekiq::ProcessSet.new.size >= 1 ? 0 : 1)'"

# Demo data the README way, then the demo user must see it.
phase_run "demo data load" "migrations applied" run_job "$web_sid" "rake demo_data:default" "bundle exec rake demo_data:default" 1500
phase_run "demo-user smoke" "demo data load" python3 "$ROOT/tests/lib/smoke.py" "$web_url" --demo

# Exit status comes from the EXIT trap: it prints the phase table, dumps
# diagnostics if anything is not "pass", tears down, and fails the run unless
# every phase passed.
