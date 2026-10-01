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
