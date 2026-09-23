#!/usr/bin/env bash
# Real-Render e2e for one deploy branch. COSTS MONEY while it runs.
#
# Creates the Blueprint's resources through the Render API (Render has no
# public API to instantiate a Blueprint), named <name>-e2e-<run>, at the
# Blueprint's own plans. Waits for the deploys to go live, runs the same smoke
# test as the local e2e against the real https URL, then deletes everything.
#
#   E2E_BRANCH        deploy branch (default sure-no-ai)
#   E2E_RUN           run id used in resource names (default: GITHUB_RUN_ID or a timestamp)
#   E2E_CONFIRM_COST  must be "yes": the caller has seen the cost estimate
#   E2E_KEEP=1        skip teardown (debugging only; the sweeper still deletes after 2h)
#   RENDER_API_KEY, optional RENDER_OWNER_ID / RENDER_REGION
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/render/lib.sh
source "$ROOT/tests/render/lib.sh"

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
log "cost while running: web starter \$7 + worker starter \$7 + key value starter \$10 + postgres basic-1gb \$19 + 10 GB disk \$2.50 = \$45.50/mo (~\$0.063/h), prorated per second"

# Datastores first; services need their connection strings.
pg_url=""; kv_url=""
while IFS= read -r row; do
  body="$(jq -c --arg o "$owner" --arg r "$RENDER_REGION" '{name, plan, version, databaseName, databaseUser, ownerId: $o, region: $r}' <<<"$row")"
  pg="$(api POST /postgres "$body")"; pg_id="$(jq -r '.id' <<<"$pg")"; remember postgres "$pg_id"
  log "created postgres $(jq -r .name <<<"$row") ($pg_id)"
done < <(jq -c '.databases[]' "$work/plan.json")
while IFS= read -r row; do
  body="$(jq -c --arg o "$owner" --arg r "$RENDER_REGION" '{name, plan, ipAllowList, ownerId: $o, region: $r}' <<<"$row")"
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
  fi
  log "created $(jq -r .type <<<"$row") $(jq -r .name <<<"$row") ($sid)"
done < <(jq -c '.services[]' "$work/plan.json")

for sid in "${!deploy_of[@]}"; do
  deadline=$((SECONDS + DEPLOY_TIMEOUT))
  while :; do
    did="${deploy_of[$sid]}"
    if [ -z "$did" ]; then
      did="$(api GET "/services/$sid/deploys?limit=1" | jq -r '.[0].deploy.id // empty')"
      deploy_of[$sid]="$did"
    fi
    st="$( [ -n "$did" ] && api GET "/services/$sid/deploys/$did" | jq -r '.status' || echo pending)"
    case "$st" in
      live) log "$sid live"; break ;;
      build_failed|update_failed|pre_deploy_failed|canceled|deactivated) die "$sid deploy $did ended $st" ;;
    esac
    (( SECONDS < deadline )) || die "$sid deploy still '$st' after ${DEPLOY_TIMEOUT}s"
    sleep 15
  done
done

[ -n "$web_url" ] || die "no web service URL"
log "smoke against $web_url"
python3 "$ROOT/tests/lib/smoke.py" "$web_url"
log "PASS $BRANCH on Render"
