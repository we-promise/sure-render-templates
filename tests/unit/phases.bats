#!/usr/bin/env bats
# Unit tests for the Render e2e phase bookkeeping and failure diagnostics.
# No Render API, no network: the helpers are exercised with stubs.

load ../lib/common

setup() {
  export RENDER_API_KEY=unused
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/tests/render/lib.sh"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/tests/render/phases.sh"
}

@test "all phases passing is green" {
  phase_expect a b
  phase_run a "" true
  phase_run b "a" true
  run phase_report
  [ "$status" -eq 0 ]
}

@test "a failing phase fails the report, and later independent phases still run" {
  phase_expect a b c
  phase_run a "" false
  phase_run b "" true
  [ "${PHASE_STATUS[a]}" = fail ]
  [ "${PHASE_STATUS[b]}" = pass ]
  run phase_report
  [ "$status" -eq 1 ]
}

@test "a phase whose prerequisite failed is skipped with the reason, never passed" {
  phase_expect load smoke
  phase_run load "" false
  phase_run smoke "load" true
  [ "${PHASE_STATUS[smoke]}" = skipped ]
  [[ "${PHASE_NOTE[smoke]}" == *"needs 'load' (fail)"* ]]
  run phase_report
  [ "$status" -eq 1 ]
}

@test "a required phase that never ran is not green" {
  phase_expect a b
  phase_run a "" true
  [ "${PHASE_STATUS[b]}" = "not run" ]
  run phase_report
  [ "$status" -eq 1 ]
  [[ "$output" == *"not run: b"* ]]
}

@test "the report is written to the Actions job summary" {
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
  phase_expect a b
  phase_run a "" true
  phase_run b "a" false
  phase_report || true
  grep -q '| a | pass |' "$GITHUB_STEP_SUMMARY"
  grep -q '| b | fail |' "$GITHUB_STEP_SUMMARY"
}

@test "dump_diagnostics prints deploys, events and logs per service and never fails" {
  state="${BATS_TEST_TMPDIR}/state.json"
  echo '{"services":["srv-1"],"postgres":[],"keyvalue":[]}' > "$state"
  api() {
    case "$2" in
      /services/srv-1/deploys*) echo '[{"deploy":{"id":"dep-1","status":"live","createdAt":"t0","trigger":"new_commit"}}]' ;;
      /services/srv-1/events*) echo '[{"event":{"timestamp":"t1","type":"server_failed","details":{"reason":{"oomKilled":{}}}}}]' ;;
      /logs*) echo '{"logs":[{"timestamp":"t2","message":"second"},{"timestamp":"t1","message":"first"}]}' ;;
    esac
  }
  run dump_diagnostics "$state" tea-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy dep-1 live"* ]]
  [[ "$output" == *"server_failed"* ]]
  [[ "$output" == *"oomKilled"* ]]
  [[ "$output" == *"t1 first"* ]]
}

@test "dump_diagnostics reports an unavailable API instead of failing" {
  state="${BATS_TEST_TMPDIR}/state.json"
  echo '{"services":["srv-1"],"postgres":[],"keyvalue":[]}' > "$state"
  api() { echo "API down"; return 1; }
  run dump_diagnostics "$state" tea-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"unavailable"* ]]
}

@test "prerequisites may be multi-word phase names, and several can be listed with |" {
  phase_expect "migrations applied" "demo data load" "demo-user smoke"
  phase_run "migrations applied" "" true
  phase_run "demo data load" "migrations applied" true
  phase_run "demo-user smoke" "migrations applied|demo data load" true
  [ "${PHASE_STATUS[demo data load]}" = pass ]
  [ "${PHASE_STATUS[demo-user smoke]}" = pass ]
  phase_run "other" "migrations applied|nope" true
  [ "${PHASE_STATUS[other]}" = skipped ]
  [[ "${PHASE_NOTE[other]}" == *"needs 'nope'"* ]]
}
