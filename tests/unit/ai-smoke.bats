#!/usr/bin/env bats
load ../lib/common

@test "AI smoke requires assistant replies, rejects failures, and preserves persistent resources" {
  run python3 "${REPO_ROOT}/tests/unit/ai_smoke_test.py"
  echo "$output"
  [ "$status" -eq 0 ]
}
