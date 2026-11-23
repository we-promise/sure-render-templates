#!/usr/bin/env bats
# Guard rails on the CI workflows themselves.

load ../lib/common

wf() { cat "${REPO_ROOT}/.github/workflows/$1"; }

@test "every workflow job has a timeout" {
  for f in "${REPO_ROOT}"/.github/workflows/*.yml; do
    jobs="$(python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print("\n".join(k for k,v in d["jobs"].items() if "timeout-minutes" not in v and "uses" not in v))' "$f")"
    [ -z "$jobs" ] || { echo "$f: no timeout-minutes on: $jobs"; false; }
  done
}

triggers() {
  python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); on=d.get("on", d.get(True)); print(sorted(on) if isinstance(on,dict) else on)' "${REPO_ROOT}/.github/workflows/$1"
}

@test "the Render e2e never runs on push or pull_request (it costs money)" {
  run triggers render-e2e.yml
  [ "$output" = "['workflow_call', 'workflow_dispatch']" ]
}

@test "only release-test calls the Render e2e: stable + alpha, never nightly, with a kill switch" {
  run grep -l 'render-e2e.yml' "${REPO_ROOT}"/.github/workflows/*.yml
  [ "$output" = "${REPO_ROOT}/.github/workflows/release-test.yml" ]
  run wf release-test.yml
  [[ "$output" == *"if: needs.plan.outputs.render == 'true'"* ]]
  [[ "$output" == *'if [ "${RENDER_ON_RELEASE:-}" = false ]; then render=false; fi'* ]]
  # nightly turns Render off in its own case arm
  run python3 -c 'import re,sys; s=open(sys.argv[1]).read(); m=re.search(r"nightly\)(.*?);;", s, re.S); print("ok" if m and "render=false" in m.group(1) else "missing")' "${REPO_ROOT}/.github/workflows/release-test.yml"
  [ "$output" = ok ]
}

@test "the Render e2e skips cleanly when RENDER_API_KEY is missing" {
  run wf render-e2e.yml
  [[ "$output" == *"if: needs.key.outputs.present == 'true'"* ]]
}

@test "release tests start only from the 6-hourly watch or by hand" {
  run triggers release-watch.yml
  [ "$output" = "['schedule', 'workflow_dispatch']" ]
  run wf release-watch.yml
  [[ "$output" == *"cron: '23 */6 * * *'"* ]]
  run triggers release-test.yml
  [ "$output" = "['workflow_dispatch']" ]
}

@test "the Render e2e always tears down" {
  run grep -A6 -E 'name: Teardown' "${REPO_ROOT}/.github/workflows/render-e2e.yml"
  [[ "$output" == *"if: always()"* ]]
}

@test "release tests run the full flow at a 2 GB e2e-only plan plus a non-blocking 512 MB onboarding check" {
  run python3 -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
jobs = d["jobs"]
# full flow: web plan input defaults to the 2 GB "standard"
inp = d.get("on", d.get(True))["workflow_dispatch"]["inputs"]
assert inp["web_plan"]["default"] == "standard", inp["web_plan"]
# onboarding check: faithful 512 MB, onboarding phases only, non-blocking
# (a reusable-workflow call cannot use continue-on-error, so the failure
# tolerance lives in the called workflow via its allow_failure input)
j = jobs["render-onboarding"]
assert "continue-on-error" not in j
assert j["if"] == "needs.plan.outputs.render == '"'"'true'"'"'"
w = j["with"]
assert w["web_plan"] == "" and w["worker_plan"] == "", w
assert w["phases"] == "migrations applied|new-user smoke", w
assert w["run_label"] == "onboarding", w
assert w["confirm_cost"] == "yes", w
assert w["allow_failure"] is True, w
print("ok")' "${REPO_ROOT}/.github/workflows/release-test.yml"
  [ "$output" = ok ]
}

@test "the Render e2e accepts a phase subset, a per-job run label and a non-blocking mode" {
  run wf render-e2e.yml
  [[ "$output" == *"E2E_PHASES"* ]]
  [[ "$output" == *"inputs.run_label"* ]]
  [[ "$output" == *"E2E_RUN"* ]]
  [[ "$output" == *"continue-on-error: \${{ inputs.allow_failure }}"* ]]
}

@test "the backstop teardown normalizes the run label like e2e.sh and keeps it out of the shell template" {
  run wf render-e2e.yml
  # label reaches the script via env, not ${{ }} expansion in run:
  [[ "$output" == *"RAW_RUN_LABEL: \${{ inputs.run_label }}"* ]]
  [[ "$output" == *"tr -cd 'a-z0-9'"* ]]
  # the teardown run: line must not expand inputs.* into shell code
  run bash -c "grep -A2 'name: Teardown' '${REPO_ROOT}/.github/workflows/render-e2e.yml' | grep 'run:' || true"
  [[ "$output" != *'run: tests/render/teardown.sh "${{ runner.temp }}/render-e2e-state.json" "${{ format'* ]]
}

@test "the test workflow fetches the deploy branches for the drift check" {
  run wf test.yml
  [[ "$output" == *"refs/heads/sure-*:refs/remotes/origin/sure-*"* ]]
}

@test "shell scripts pass shellcheck" {
  command -v shellcheck >/dev/null || { echo "shellcheck not installed"; false; }
  shellcheck "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/tests/render/*.sh "${REPO_ROOT}"/tests/run.sh "${REPO_ROOT}"/tests/lib/tap-annotate.sh "${REPO_ROOT}"/tests/lib/stubs/render-curl "${REPO_ROOT}"/tests/lib/stubs/render-python3 "${REPO_ROOT}"/tests/release/*.sh
}

@test "a run that skips the Render e2e says so in the job summary and a notice" {
  run grep -c 'NOT run' "${REPO_ROOT}/.github/workflows/release-test.yml"
  [ "$output" -ge 2 ]
}
