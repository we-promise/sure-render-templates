#!/usr/bin/env bats
# tests/release/watch.sh picks the right Sure releases and dispatches each once.

load ../lib/common

setup() {
  export DRY_RUN=1
  export RELEASES_FILE="${BATS_TEST_TMPDIR}/releases.json"
  export RUNS_FILE="${BATS_TEST_TMPDIR}/runs.txt"
  export NIGHTLY_DIGEST="sha256:1111"
  : > "$RUNS_FILE"
  cat > "$RELEASES_FILE" <<'JSON'
[
  {"tag_name":"v0.7.6-rc.1","prerelease":true,"draft":false},
  {"tag_name":"v0.7.6","prerelease":false,"draft":true},
  {"tag_name":"v0.7.5-alpha.10","prerelease":true,"draft":false},
  {"tag_name":"v0.7.5-alpha.9","prerelease":true,"draft":false},
  {"tag_name":"v0.7.4","prerelease":false,"draft":false},
  {"tag_name":"v0.7.3","prerelease":false,"draft":false}
]
JSON
}

@test "newest non-draft stable and newest alpha are dispatched" {
  run "${REPO_ROOT}/tests/release/watch.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatch: stable v0.7.4"* ]]
  [[ "$output" == *"dispatch: latest v0.7.5-alpha.10"* ]]
  [[ "$output" != *"rc.1"* ]]
  [[ "$output" != *"v0.7.6"* ]]
}

@test "a release with an existing run (pass or fail) is not dispatched again" {
  printf '%s\n' "release test stable v0.7.4" "release test latest v0.7.5-alpha.9" > "$RUNS_FILE"
  run "${REPO_ROOT}/tests/release/watch.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already tested: stable v0.7.4"* ]]
  [[ "$output" == *"dispatch: latest v0.7.5-alpha.10"* ]]
}

@test "a hotfix release counts as stable" {
  printf '[{"tag_name":"v0.7.1-hotfix.1","prerelease":false,"draft":false}]' > "$RELEASES_FILE"
  run "${REPO_ROOT}/tests/release/watch.sh"
  [[ "$output" == *"dispatch: stable v0.7.1-hotfix.1"* ]]
  [[ "$output" == *"no latest release found"* ]]
}

@test "a new nightly digest is dispatched once" {
  run "${REPO_ROOT}/tests/release/watch.sh"
  [[ "$output" == *"dispatch: nightly sha256:1111"* ]]
  echo "release test nightly sha256:1111" > "$RUNS_FILE"
  run "${REPO_ROOT}/tests/release/watch.sh"
  [[ "$output" == *"already tested: nightly sha256:1111"* ]]
  NIGHTLY_DIGEST="sha256:2222" run "${REPO_ROOT}/tests/release/watch.sh"
  [[ "$output" == *"dispatch: nightly sha256:2222"* ]]
}

@test "no nightly image means no nightly dispatch, not a failure" {
  NIGHTLY_DIGEST="" run "${REPO_ROOT}/tests/release/watch.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no nightly release found"* ]]
}
