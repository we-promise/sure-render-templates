#!/usr/bin/env bats
# Drives the REAL tests/render/e2e.sh (and teardown.sh, lib.sh, phases.sh,
# blueprint.py) against a stubbed Render API and a stubbed smoke.py. Nothing
# billable is created; what is not exercised is Render itself and smoke.py's
# HTTP flow. Checks the promises that matter: independent phases keep running,
# phases behind a failed prerequisite are skipped, diagnostics are printed
# BEFORE teardown, and the verdict is nonzero unless every phase passed.

load ../lib/common

setup() {
  git -C "${REPO_ROOT}" rev-parse --verify -q "$(remote_ref sure-no-ai)" >/dev/null \
    || { echo "deploy branches not fetched (tests/run.sh does this)"; false; }
  export STUB_DIR="${BATS_TEST_TMPDIR}/stub"; mkdir -p "$STUB_DIR" "${BATS_TEST_TMPDIR}/bin"
  : > "$STUB_DIR/calls.log"
  export REAL_PYTHON3="$(command -v python3)"
  ln -s "${REPO_ROOT}/tests/lib/stubs/render-curl" "${BATS_TEST_TMPDIR}/bin/curl"
  ln -s "${REPO_ROOT}/tests/lib/stubs/render-python3" "${BATS_TEST_TMPDIR}/bin/python3"
  printf '#!/bin/sh\nexit 0\n' > "${BATS_TEST_TMPDIR}/bin/sleep"; chmod +x "${BATS_TEST_TMPDIR}/bin/sleep"
  export PATH="${BATS_TEST_TMPDIR}/bin:$PATH"
  export RENDER_API_KEY=stub RENDER_OWNER_ID=tea-stub E2E_CONFIRM_COST=yes
  export E2E_IMAGE_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export E2E_BRANCH=sure-no-ai E2E_RUN=stub1 E2E_STATE="${BATS_TEST_TMPDIR}/state.json"
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
}

calls() { cat "$STUB_DIR/calls.log"; }
line_of() { grep -n -m1 -- "$1" "$STUB_DIR/calls.log" | cut -d: -f1; }

@test "all phases pass: exit 0, no diagnostics, teardown ran" {
  run "${REPO_ROOT}/tests/render/e2e.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"pinned image for this run: ghcr.io/we-promise/sure:stable -> ghcr.io/we-promise/sure@sha256:aaa"* ]]
  [[ "$output" == *"PASS sure-no-ai on Render (all phases passed)"* ]]
  [[ "$output" == *"pass: demo-user smoke"* ]]
  [[ "$output" == *"OOM events sweep: 2/2 service(s) fully queried for the whole run, none found"* ]]
  [ "$(calls | grep -c '^GET /logs')" -eq 0 ]
  calls | grep -q '^DELETE /services/srv-web'
  calls | grep -q '^DELETE /postgres/pg-1'
}

@test "an OOM event anywhere in the run is reported, not swallowed" {
  STUB_EVENTS_OOM=1 run "${REPO_ROOT}/tests/render/e2e.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"OOM events sweep: OOM events FOUND"* ]]
  [[ "$output" == *"oomKilled"* ]]
}

@test "an unavailable events query is UNKNOWN, never 'none found'" {
  STUB_EVENTS_UNAVAILABLE=1 run "${REPO_ROOT}/tests/render/e2e.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"UNKNOWN for: srv-web(query-failed) srv-worker(query-failed)"* ]]
  [[ "$output" == *"no whole-run OOM claim"* ]]
  [[ "$output" != *"none found"* ]]
}

@test "first deploy fails with a transient DB signature: diagnostics preserved, one retry of the same config, then green" {
  STUB_DEPLOY_FAIL=transient run "${REPO_ROOT}/tests/render/e2e.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"preserving its diagnostics before one retry of the SAME image/config"* ]]
  [[ "$output" == *"transient-looking failure evidence:"* ]]
  [[ "$output" == *"postgres://***@"* ]]
  [[ "$output" != *"SUPERSECRETPW"* ]]
  [[ "$output" == *"retry deploy dep-retry started"* ]]
  [[ "$output" == *"verdict includes one retry"* ]]
  [[ "$output" == *"PASS sure-no-ai on Render (all phases passed)"* ]]
  calls | grep -q '^POST /services/srv-web/deploys$'
}

@test "repeated refusal: exactly one retry, then run stays red and teardown runs" {
  STUB_DEPLOY_FAIL=repeated run "${REPO_ROOT}/tests/render/e2e.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"retry deploy dep-retry started"* ]]
  [[ "$output" == *"ended update_failed"* ]]
  [ "$(calls | grep -cE '^POST /services/.+/deploys$')" -eq 1 ]
  calls | grep -q '^DELETE /services/srv-web'
  calls | grep -q '^DELETE /postgres/pg-1'
}

@test "first deploy fails without a transient signature: no retry, run stays red" {
  STUB_DEPLOY_FAIL=persistent run "${REPO_ROOT}/tests/render/e2e.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ended update_failed"* ]]
  [[ "$output" == *"not run: new-user smoke"* ]]
  [ "$(calls | grep -cE '^POST /services/.+/deploys$')" -eq 0 ]
  calls | grep -q '^DELETE /services/srv-web'
}

@test "new-user smoke fails: independent phases still run, diagnostics come before teardown, exit nonzero" {
  STUB_SMOKE_RC=1 run "${REPO_ROOT}/tests/render/e2e.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"fail: new-user smoke"* ]]
  [[ "$output" == *"pass: Sidekiq worker registered"* ]]
  [[ "$output" == *"pass: demo data load"* ]]
  [[ "$output" == *"pass: demo-user smoke"* ]]
  [[ "$output" != *"PASS sure-no-ai on Render"* ]]
  calls | grep -q '^SMOKE demo'
  logs_at="$(line_of '^GET /logs')"; del_at="$(line_of '^DELETE ')"
  [ -n "$logs_at" ] && [ -n "$del_at" ] && [ "$logs_at" -lt "$del_at" ]
  calls | grep -q 'type=request&statusCode=5'
  grep -q '| new-user smoke | fail |' "$GITHUB_STEP_SUMMARY"
}

@test "demo data load fails: demo-user smoke is skipped (not passed), the rest still ran, exit nonzero" {
  STUB_FAIL_JOB="demo_data:default" run "${REPO_ROOT}/tests/render/e2e.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"fail: demo data load"* ]]
  [[ "$output" == *"skipped: demo-user smoke (needs 'demo data load' (fail))"* ]]
  [[ "$output" == *"pass: new-user smoke"* ]]
  [[ "$output" == *"pass: Sidekiq worker registered"* ]]
  ! calls | grep -q '^SMOKE demo'
  logs_at="$(line_of '^GET /logs')"; del_at="$(line_of '^DELETE ')"
  [ "$logs_at" -lt "$del_at" ]
}

@test "migrations fail: every dependent phase is skipped, nothing is faked, teardown still runs" {
  STUB_FAIL_JOB="needs_migration" run "${REPO_ROOT}/tests/render/e2e.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"fail: migrations applied"* ]]
  for p in "new-user smoke" "Sidekiq worker registered" "demo data load" "demo-user smoke"; do
    [[ "$output" == *"skipped: $p"* ]] || { echo "$p not skipped"; echo "$output"; false; }
  done
  ! calls | grep -q '^SMOKE'
  calls | grep -q '^DELETE /services/srv-web'
}

@test "a failed demo smoke alone fails the run" {
  STUB_DEMO_SMOKE_RC=1 run "${REPO_ROOT}/tests/render/e2e.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"fail: demo-user smoke"* ]]
  [[ "$output" == *"pass: demo data load"* ]]
}
