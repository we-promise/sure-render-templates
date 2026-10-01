#!/usr/bin/env bats
# Creation-only Render API translation must mirror Blueprint sizing defaults.
load ../lib/common

setup() {
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK"
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
