#!/usr/bin/env bats
# Static invariants over every Blueprint this repo ships: the three flavor
# templates in branches/, the root render.yaml, and the six deploy-branch
# render.yaml files as generated (see tests/lib/common.bash).

load ../lib/common

setup_file() {
  export GEN_DIR="$(mktemp -d)"
  for b in "${DEPLOY_BRANCHES[@]}"; do
    expected_render_yaml "$b" > "${GEN_DIR}/$b.yaml"
  done
}

teardown_file() {
  rm -rf "${GEN_DIR}"
}

q() { $BPQ "$@"; }

@test "every deploy branch pins the Sure image tag its name promises" {
  for b in "${DEPLOY_BRANCHES[@]}"; do
    f="${GEN_DIR}/$b.yaml"
    tags="$(q "$f" 'sorted({s["image"]["url"] for s in svcs if s.get("runtime")=="image"})')"
    [ "$tags" = "ghcr.io/we-promise/sure:$(tag_of "$b")" ] || { echo "$b: $tags"; false; }
  done
}

@test "the root render.yaml is the sure-no-ai stable Blueprint" {
  diff "${REPO_ROOT}/render.yaml" "${GEN_DIR}/sure-no-ai.yaml"
}

@test "every deployable service has autoDeployTrigger off" {
  for f in "${REPO_ROOT}"/branches/*/render.yaml "${REPO_ROOT}/render.yaml"; do
    run q "$f" 'all(s.get("autoDeployTrigger") is False for s in svcs if s["type"] in ("web","worker"))'
    [ "$output" = "true" ] || { echo "$f"; false; }
  done
}

@test "Postgres is basic-1gb on major version 18 (immutable after creation)" {
  for f in "${REPO_ROOT}"/branches/*/render.yaml; do
    [ "$(q "$f" '[(d["plan"], str(d["postgresMajorVersion"])) for d in dbs]')" = "('basic-1gb', '18')" ] || { echo "$f"; false; }
  done
}

@test "Sure web + worker use the documented starter sizing and Puma 1x3 tuning" {
  for f in "${REPO_ROOT}"/branches/*/render.yaml; do
    for name in sure-web sure-worker; do
      run q "$f" "[s['plan'] for s in svcs if s['name']=='$name']"
      [ "$output" = "starter" ] || { echo "$f $name plan=$output"; false; }
      run q "$f" "{e['key']: e.get('value') for s in svcs if s['name']=='$name' for e in s['envVars']}.get('WEB_CONCURRENCY')"
      [ "$output" = "1" ]
      run q "$f" "{e['key']: e.get('value') for s in svcs if s['name']=='$name' for e in s['envVars']}.get('RAILS_MAX_THREADS')"
      [ "$output" = "3" ]
    done
  done
}

@test "sure-web keeps its health check and persistent storage disk" {
  for f in "${REPO_ROOT}"/branches/*/render.yaml; do
    [ "$(q "$f" '[s.get("healthCheckPath") for s in svcs if s["name"]=="sure-web"]')" = "/" ]
    [ "$(q "$f" '[s["disk"]["mountPath"] for s in svcs if s["name"]=="sure-web"]')" = "/rails/storage" ]
  done
}

@test "sure-worker runs Sidekiq and shares sure-web's SECRET_KEY_BASE" {
  for f in "${REPO_ROOT}"/branches/*/render.yaml; do
    [ "$(q "$f" '[s.get("dockerCommand") for s in svcs if s["name"]=="sure-worker"]')" = "bundle exec sidekiq" ]
    run q "$f" '[e["fromService"] for s in svcs if s["name"]=="sure-worker" for e in s["envVars"] if e["key"]=="SECRET_KEY_BASE"]'
    [ "$output" = "{'type': 'web', 'name': 'sure-web', 'envVarKey': 'SECRET_KEY_BASE'}" ] || { echo "$f $output"; false; }
  done
}

@test "every env var reference points at a resource that exists" {
  for f in "${REPO_ROOT}"/branches/*/render.yaml; do
    run q "$f" '[s["name"] + "." + e["key"] for s in svcs for e in s.get("envVars",[]) if ("fromDatabase" in e and e["fromDatabase"]["name"] not in [d["name"] for d in dbs]) or ("fromService" in e and not any(t["name"]==e["fromService"]["name"] and t["type"]==e["fromService"]["type"] for t in svcs))]'
    [ -z "$output" ] || { echo "$f dangling: $output"; false; }
  done
}

@test "compose/Render translation accepts the no-AI Blueprints (no unsupported features)" {
  # simple-ai (sync:false prompted secrets) and external-ai (docker-runtime
  # AlphaClaw) join in their own slices.
  for b in sure-no-ai sure-no-ai-latest; do
    python3 "${REPO_ROOT}/tests/lib/blueprint.py" compose "${GEN_DIR}/$b.yaml" >/dev/null
    python3 "${REPO_ROOT}/tests/lib/blueprint.py" render-plan "${GEN_DIR}/$b.yaml" t0 >/dev/null
  done
}

@test "no-AI Blueprints ship every AI setting blank" {
  f="${REPO_ROOT}/branches/sure-no-ai/render.yaml"
  for name in sure-web sure-worker; do
    for key in OPENAI_ACCESS_TOKEN MCP_API_TOKEN MCP_USER_EMAIL ASSISTANT_TYPE EXTERNAL_ASSISTANT_URL EXTERNAL_ASSISTANT_TOKEN; do
      run q "$f" "[e.get('value') for s in svcs if s['name']=='$name' for e in s['envVars'] if e['key']=='$key']"
      [ "$status" -eq 0 ]
      # exactly one entry, and it is the empty string
      [ "$(q "$f" "len([e for s in svcs if s['name']=='$name' for e in s['envVars'] if e['key']=='$key' and e.get('value')==''])")" = "1" ] || { echo "$name.$key"; false; }
    done
  done
}

@test "the self-hosted SSL settings are on for Sure services" {
  for f in "${REPO_ROOT}"/branches/*/render.yaml; do
    for key in SELF_HOSTED RAILS_FORCE_SSL RAILS_ASSUME_SSL; do
      [ "$(q "$f" "sorted({e.get('value') for s in svcs if s['name'] in ('sure-web','sure-worker') for e in s['envVars'] if e['key']=='$key'})")" = "true" ] || { echo "$f $key"; false; }
    done
  done
}
