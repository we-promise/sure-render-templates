#!/usr/bin/env bats
# Guard rails on the CI workflows themselves.

load ../lib/common

wf() { cat "${REPO_ROOT}/.github/workflows/$1"; }

@test "every workflow job has a timeout" {
  for f in "${REPO_ROOT}"/.github/workflows/*.yml; do
    jobs="$(python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print("\n".join(k for k,v in d["jobs"].items() if "timeout-minutes" not in v))' "$f")"
    [ -z "$jobs" ] || { echo "$f: no timeout-minutes on: $jobs"; false; }
  done
}

@test "the Render e2e never runs on push or pull_request (it costs money)" {
  run python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); on=d.get("on", d.get(True)); print(sorted(on) if isinstance(on,dict) else on)' "${REPO_ROOT}/.github/workflows/render-e2e.yml"
  [ "$output" = "['workflow_dispatch']" ]
}

@test "the Render e2e always tears down" {
  run grep -A3 -E 'name: Teardown' "${REPO_ROOT}/.github/workflows/render-e2e.yml"
  [[ "$output" == *"if: always()"* ]]
}

@test "the test workflow fetches the deploy branches for the drift check" {
  run wf test.yml
  [[ "$output" == *"refs/heads/sure-*:refs/remotes/origin/sure-*"* ]]
}

@test "shell scripts pass shellcheck" {
  command -v shellcheck >/dev/null || { echo "shellcheck not installed"; false; }
  shellcheck "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/tests/render/*.sh "${REPO_ROOT}"/tests/run.sh
}
