#!/usr/bin/env bats
# Creation-only Render API translation must preserve Blueprint configuration.
load ../lib/common

setup() {
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK"
}

@test "Key Value eviction policies reach the Render plan and create request unchanged" {
  for policy in noeviction allkeys-lru omitted; do
    python3 - "${REPO_ROOT}/render.yaml" "$WORK/render.yaml" "$policy" <<'PY'
import sys, yaml
bp = yaml.safe_load(open(sys.argv[1]))
kv = next(s for s in bp["services"] if s["type"] == "keyvalue")
if sys.argv[3] == "omitted":
    kv.pop("maxmemoryPolicy")
else:
    kv["maxmemoryPolicy"] = sys.argv[3]
yaml.safe_dump(bp, open(sys.argv[2], "w"))
PY
    python3 "${REPO_ROOT}/tests/lib/blueprint.py" render-plan "$WORK/render.yaml" t0 > "$WORK/plan.json"
    # Exercise the same serializer the real E2E uses, with no API calls.
    RENDER_API_KEY=test-only bash -c '
      source "$1/tests/render/lib.sh"
      jq -c ".keyvalues[0]" "$2" | keyvalue_create_body owner-test oregon
    ' _ "$REPO_ROOT" "$WORK/plan.json" > "$WORK/request.json"
    run python3 - "$WORK/plan.json" "$WORK/request.json" "$policy" <<'PY'
import json, sys
kv = json.load(open(sys.argv[1]))["keyvalues"][0]
request = json.load(open(sys.argv[2]))
for resource in (kv, request):
    if sys.argv[3] == "omitted":
        assert "maxmemoryPolicy" not in resource
    else:
        assert resource["maxmemoryPolicy"] == sys.argv[3]
assert request["name"] == "sure-redis-t0"
assert request["plan"] == "starter"
assert request["ipAllowList"] == []
assert request["ownerId"] == "owner-test"
assert request["region"] == "oregon"
assert "blueprintName" not in request
PY
    [ "$status" -eq 0 ]
  done
}

@test "render-plan uses the paid creation default when web and worker plans are omitted" {
  python3 "${REPO_ROOT}/tests/lib/blueprint.py" render-plan "${REPO_ROOT}/render.yaml" t0 > "$WORK/plan.json"
  run python3 - "$WORK/plan.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert [(s["blueprintName"], s["serviceDetails"]["plan"]) for s in p["services"]] == [
    ("sure-web", "starter"), ("sure-worker", "starter")]
assert [s["plan"] for s in p["keyvalues"]] == ["starter"]
assert [d["plan"] for d in p["databases"]] == ["basic_1gb"]
PY
  [ "$status" -eq 0 ]
}

@test "render-plan honors explicit operator plan overrides" {
  python3 - "${REPO_ROOT}/render.yaml" "$WORK/render.yaml" <<'PY'
import sys, yaml
bp = yaml.safe_load(open(sys.argv[1]))
for s in bp["services"]:
    if s["type"] in ("web", "worker"):
        s["plan"] = "1c-2g" if s["type"] == "web" else "standard"
yaml.safe_dump(bp, open(sys.argv[2], "w"))
PY
  python3 "${REPO_ROOT}/tests/lib/blueprint.py" render-plan "$WORK/render.yaml" t0 > "$WORK/plan.json"
  run python3 - "$WORK/plan.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert [s["serviceDetails"]["plan"] for s in p["services"]] == ["1c-2g", "standard"]
PY
  [ "$status" -eq 0 ]
}

@test "render-plan honors E2E_PLAN_WEB/E2E_PLAN_WORKER env overrides" {
  E2E_PLAN_WEB=standard E2E_PLAN_WORKER=1c-2g \
    python3 "${REPO_ROOT}/tests/lib/blueprint.py" render-plan "${REPO_ROOT}/render.yaml" t0 > "$WORK/plan.json"
  run python3 - "$WORK/plan.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert [(s["blueprintName"], s["serviceDetails"]["plan"]) for s in p["services"]] == [
    ("sure-web", "standard"), ("sure-worker", "1c-2g")]
PY
  [ "$status" -eq 0 ]
}

@test "an explicit Blueprint plan beats the e2e env override" {
  python3 - "${REPO_ROOT}/render.yaml" "$WORK/render.yaml" <<'PY'
import sys, yaml
bp = yaml.safe_load(open(sys.argv[1]))
for s in bp["services"]:
    if s["type"] == "web":
        s["plan"] = "1c-2g"
yaml.safe_dump(bp, open(sys.argv[2], "w"))
PY
  E2E_PLAN_WEB=standard E2E_PLAN_WORKER=standard \
    python3 "${REPO_ROOT}/tests/lib/blueprint.py" render-plan "$WORK/render.yaml" t0 > "$WORK/plan.json"
  run python3 - "$WORK/plan.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert [s["serviceDetails"]["plan"] for s in p["services"]] == ["1c-2g", "standard"]
PY
  [ "$status" -eq 0 ]
}

@test "compose suffixes service names and resolves host references to the suffixed names" {
  export E2E_PROMPT_SETUP_PASSWORD=s E2E_PROMPT_GITHUB_TOKEN=g E2E_PROMPT_GITHUB_WORKSPACE_REPO=r E2E_PROMPT_MCP_USER_EMAIL=user@example.com
  python3 "${REPO_ROOT}/tests/lib/blueprint.py" compose "${REPO_ROOT}/branches/sure-external-ai/render.yaml" > "$WORK/compose.yaml"
  run python3 - "$WORK/compose.yaml" "${REPO_ROOT}/branches/sure-external-ai" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))["services"]
assert set(c) == {"postgres", "redis", "alphaclaw-e2e", "sure-web-e2e", "sure-worker-e2e"}, set(c)
assert c["alphaclaw-e2e"]["environment"]["SURE_WEB_HOST"] == "sure-web-e2e"
assert c["sure-web-e2e"]["environment"]["ALPHACLAW_HOST"] == "alphaclaw-e2e"
assert c["alphaclaw-e2e"]["build"]["context"] == sys.argv[2]
assert "ports" in c["sure-web-e2e"] and "ports" not in c["alphaclaw-e2e"]
# A prompted value, including one the worker copies from web.
assert c["sure-worker-e2e"]["environment"]["MCP_USER_EMAIL"] == "user@example.com"
# dockerCommand keeps its shell quoting, with $ escaped from compose interpolation.
cmd = c["sure-web-e2e"]["command"]
assert cmd[:2] == ["/bin/sh", "-c"] and len(cmd) == 3, cmd
assert "$${ALPHACLAW_HOST}" in cmd[2] and "${" not in cmd[2].replace("$${", ""), cmd
PY
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "compose fails on a prompted value with no E2E_PROMPT_ variable" {
  run env -u E2E_PROMPT_SETUP_PASSWORD E2E_PROMPT_GITHUB_TOKEN=g E2E_PROMPT_GITHUB_WORKSPACE_REPO=r E2E_PROMPT_MCP_USER_EMAIL=u \
    python3 "${REPO_ROOT}/tests/lib/blueprint.py" compose "${REPO_ROOT}/branches/sure-external-ai/render.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"alphaclaw.SETUP_PASSWORD"*"E2E_PROMPT_SETUP_PASSWORD"* ]]
}

@test "compose caps app services without swap only when E2E_MEM_LIMIT is set" {
  python3 "${REPO_ROOT}/tests/lib/blueprint.py" compose "${REPO_ROOT}/render.yaml" > "$WORK/uncapped.yaml"
  E2E_MEM_LIMIT=512m python3 "${REPO_ROOT}/tests/lib/blueprint.py" compose "${REPO_ROOT}/render.yaml" > "$WORK/capped.yaml"
  run python3 - "$WORK/uncapped.yaml" "$WORK/capped.yaml" <<'PY'
import sys, yaml
free, capped = (yaml.safe_load(open(f))["services"] for f in sys.argv[1:])
assert not any("mem_limit" in c or "memswap_limit" in c for c in free.values())
for name, c in capped.items():
    if name in ("postgres", "redis"):
        assert "mem_limit" not in c, name
    else:
        assert c["mem_limit"] == c["memswap_limit"] == "512m", (name, c)
PY
  echo "$output"
  [ "$status" -eq 0 ]
}
