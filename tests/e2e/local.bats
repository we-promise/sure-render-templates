#!/usr/bin/env bats
# Local e2e: boot a deploy branch's Blueprint in docker compose and prove it
# works the way it would on Render. The compose file is generated from the
# branch's own render.yaml (tests/lib/blueprint.py), so env vars, image tag,
# disk and worker command can't drift from what users deploy.
#
#   E2E_BRANCH   deploy branch to test (default: sure-no-ai)
#   E2E_WEB_PORT host port for sure-web (default: 3000)
#   E2E_IMAGE    optional Sure image to run instead of the branch's pin, e.g.
#                ghcr.io/we-promise/sure@sha256:... for a nightly build
#
# Needs docker (with compose v2), curl, python3 + PyYAML, and the deploy
# branch fetched into refs/remotes/origin.

load ../lib/common

BOOT_TIMEOUT="${E2E_BOOT_TIMEOUT:-600}"

setup_file() {
  export E2E_BRANCH="${E2E_BRANCH:-sure-no-ai}"
  export E2E_WEB_PORT="${E2E_WEB_PORT:-3000}"
  export E2E_DIR="$(mktemp -d)"
  export COMPOSE_PROJECT_NAME="sure-e2e-$$"
  git -C "${REPO_ROOT}" show "$(remote_ref "$E2E_BRANCH"):render.yaml" > "${E2E_DIR}/render.yaml"
  if [ -n "${E2E_IMAGE:-}" ]; then
    sed -i -E "s#(url: )ghcr\.io/we-promise/sure[:@][^[:space:]]+#\1${E2E_IMAGE}#" "${E2E_DIR}/render.yaml"
  fi
  python3 "${REPO_ROOT}/tests/lib/blueprint.py" compose "${E2E_DIR}/render.yaml" > "${E2E_DIR}/compose.yaml"
  export DC="docker compose -f ${E2E_DIR}/compose.yaml"
  $DC up -d --quiet-pull
  # Wait for Rails (db:prepare runs in the web entrypoint before the server).
  local deadline=$((SECONDS + BOOT_TIMEOUT))
  until curl -fsS -o /dev/null -H 'X-Forwarded-Proto: https' "http://127.0.0.1:${E2E_WEB_PORT}/up"; do
    if (( SECONDS > deadline )); then
      $DC ps -a >&3; $DC logs --tail 80 >&3
      echo "sure-web never answered /up within ${BOOT_TIMEOUT}s" >&3
      return 1
    fi
    sleep 5
  done
}

teardown_file() {
  if [ -n "${DC:-}" ]; then
    # Always keep a log tail for CI annotations / debugging.
    $DC ps -a > "${E2E_LOG_FILE:-/tmp/sure-e2e-logs.txt}" 2>&1 || true
    $DC logs --no-color --tail 120 >> "${E2E_LOG_FILE:-/tmp/sure-e2e-logs.txt}" 2>&1 || true
    $DC down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf "${E2E_DIR:-/nonexistent}"
}

redis() { $DC exec -T redis redis-cli "$@"; }

@test "compose runs the image tag the branch pins (or E2E_IMAGE)" {
  want="${E2E_IMAGE:-ghcr.io/we-promise/sure:$(tag_of "$E2E_BRANCH")}"
  run bash -c "$DC config --images | sort -u | grep we-promise/sure"
  [ "$output" = "$want" ]
}

@test "web and worker are running, not restart-looping" {
  for svc in sure-web sure-worker; do
    state="$($DC ps --format '{{.State}}' "$svc")"
    [ "$state" = "running" ] || { echo "$svc state=$state"; false; }
  done
}

@test "database is fully migrated" {
  run $DC exec -T sure-web ./bin/rails runner 'exit(ActiveRecord::Base.connection_pool.migration_context.needs_migration? ? 1 : 0)'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "app runs as behind a TLS proxy: https links and HSTS even on plain http" {
  # Sure defaults RAILS_ASSUME_SSL=true and RAILS_FORCE_SSL=true (Render terminates
  # TLS), so plain http is not redirected; it is treated as https instead.
  run curl -s -D - -o /dev/null "http://127.0.0.1:${E2E_WEB_PORT}/"
  grep -qi '^strict-transport-security:' <<<"$output" || { echo "$output"; false; }
  loc="$(grep -i '^location:' <<<"$output" | tr -d '\r' | awk '{print $2}')"
  [ -z "$loc" ] || [[ "$loc" == https://* ]] || { echo "$output"; false; }
}

@test "smoke: health, sign up, log in (through the Render-style proxy header)" {
  run python3 "${REPO_ROOT}/tests/lib/smoke.py" "http://127.0.0.1:${E2E_WEB_PORT}" --forwarded-proto https
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "Sidekiq worker is registered in Redis" {
  deadline=$((SECONDS + 120))
  until [ "$(redis SCARD processes)" -ge 1 ] 2>/dev/null; do
    (( SECONDS < deadline )) || { $DC logs --tail 40 sure-worker; false; }
    sleep 3
  done
}

@test "a job enqueued by web is processed by the worker" {
  before="$(redis GET stat:processed)"; before="${before:-0}"
  # SyncCleanerJob is Sure's hourly housekeeping job; on a fresh DB it is a no-op.
  run $DC exec -T sure-web ./bin/rails runner 'SyncCleanerJob.perform_later'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  deadline=$((SECONDS + 120))
  while :; do
    now="$(redis GET stat:processed)"; now="${now:-0}"
    (( now > before )) && break
    (( SECONDS < deadline )) || { echo "stat:processed stayed at $now"; $DC logs --tail 40 sure-worker; false; }
    sleep 3
  done
}
