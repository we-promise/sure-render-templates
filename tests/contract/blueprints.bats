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

@test "compose/Render translation accepts no-AI and simple-AI Blueprints" {
  # This validates generated PR templates, not the published deploy branches.
  # External AI still uses unsupported docker-runtime services/prompted secrets.
  for b in sure-no-ai sure-no-ai-latest sure-simple-ai sure-simple-ai-latest; do
    python3 "${REPO_ROOT}/tests/lib/blueprint.py" compose "${GEN_DIR}/$b.yaml" >/dev/null
    python3 "${REPO_ROOT}/tests/lib/blueprint.py" render-plan "${GEN_DIR}/$b.yaml" t0 >/dev/null
  done
}

@test "OpenAI settings stay outside every Blueprint so environment groups can supply them" {
  for f in "${REPO_ROOT}/render.yaml" "${REPO_ROOT}"/branches/*/render.yaml "${GEN_DIR}"/*.yaml; do
    # This rejects value, sync:false, generateValue and fromService entries alike.
    # A copied token on the worker would override its group just like a literal.
    run q "$f" '[s["name"] + "." + e["key"] for s in svcs for e in s.get("envVars", []) if e.get("key") in ("OPENAI_ACCESS_TOKEN", "OPENAI_MODEL", "OPENAI_URI_BASE")]'
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "$f overrides: $output"; false; }
    run q "$f" '[s["name"] + "." + e["key"] for s in svcs for e in s.get("envVars", []) if e.get("fromService", {}).get("envVarKey") in ("OPENAI_ACCESS_TOKEN", "OPENAI_MODEL", "OPENAI_URI_BASE")]'
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "$f references unmanaged settings: $output"; false; }
  done
}

@test "no-AI Blueprints declare only infrastructure and boot settings" {
  for f in "${REPO_ROOT}/render.yaml" "${REPO_ROOT}/branches/sure-no-ai/render.yaml" "${GEN_DIR}"/sure-no-ai*.yaml; do
    run q "$f" '[s["name"] + "." + e["key"] for s in svcs for e in s.get("envVars", []) if e.get("key") not in ("PORT", "DATABASE_URL", "REDIS_URL", "SECRET_KEY_BASE", "SELF_HOSTED", "WEB_CONCURRENCY", "RAILS_MAX_THREADS", "RAILS_FORCE_SSL", "RAILS_ASSUME_SSL")]'
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "$f unexpected optional config: $output"; false; }
  done
}

@test "templates do not pin no-op optional settings or require SSO mail or telemetry credentials" {
  for f in "${REPO_ROOT}/render.yaml" "${REPO_ROOT}"/branches/*/render.yaml "${GEN_DIR}"/*.yaml; do
    run q "$f" '[s["name"] + "." + e["key"] for s in svcs for e in s.get("envVars", []) if e.get("value") == "" or e.get("key") in ("AI_DEBUG_MODE", "EXTERNAL_ASSISTANT_AGENT_ID", "EXTERNAL_ASSISTANT_SESSION_KEY", "EXTERNAL_ASSISTANT_ALLOWED_EMAILS") or e.get("key", "").startswith(("AUTH_", "OIDC_", "GOOGLE_OAUTH_", "GITHUB_CLIENT_", "SMTP_", "POSTHOG_", "LANGFUSE_"))]'
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "$f unexpected optional config: $output"; false; }
  done
}

@test "AI profiles retain their existing pgvector model and dimensions" {
  for f in "${REPO_ROOT}/branches/sure-simple-ai/render.yaml" "${REPO_ROOT}/branches/sure-external-ai/render.yaml" "${GEN_DIR}"/sure-simple-ai*.yaml "${GEN_DIR}"/sure-external-ai*.yaml; do
    for name in sure-web sure-worker; do
      run q "$f" "{e['key']: e.get('value') for s in svcs if s['name']=='$name' for e in s['envVars'] if e['key'] in ('VECTOR_STORE_PROVIDER', 'EMBEDDING_MODEL', 'EMBEDDING_DIMENSIONS')}"
      [ "$status" -eq 0 ]
      [ "$output" = "{'VECTOR_STORE_PROVIDER': 'pgvector', 'EMBEDDING_MODEL': 'text-embedding-3-small', 'EMBEDDING_DIMENSIONS': '1536'}" ] || { echo "$f $name: $output"; false; }
    done
  done
}

@test "external AI retains its assistant selection and generated gateway and MCP wiring" {
  for f in "${REPO_ROOT}/branches/sure-external-ai/render.yaml" "${GEN_DIR}"/sure-external-ai*.yaml; do
    for name in sure-web sure-worker; do
      run q "$f" "[e.get('value') for s in svcs if s['name']=='$name' for e in s['envVars'] if e['key']=='ASSISTANT_TYPE']"
      [ "$status" -eq 0 ]
      [ "$output" = "external" ]
      run q "$f" "[e.get('value') for s in svcs if s['name']=='$name' for e in s['envVars'] if e['key']=='EXTERNAL_ASSISTANT_URL']"
      [ "$status" -eq 0 ]
      [ "$output" = "http://alphaclaw:3000/v1/chat/completions" ]
      run q "$f" "[e.get('fromService') for s in svcs if s['name']=='$name' for e in s['envVars'] if e['key']=='EXTERNAL_ASSISTANT_TOKEN']"
      [ "$status" -eq 0 ]
      [ "$output" = "{'type': 'web', 'name': 'alphaclaw', 'envVarKey': 'OPENCLAW_GATEWAY_TOKEN'}" ]
    done
    [ "$(q "$f" '[e.get("generateValue") for s in svcs if s["name"]=="alphaclaw" for e in s["envVars"] if e["key"]=="OPENCLAW_GATEWAY_TOKEN"] == [True]')" = "true" ]
    [ "$(q "$f" '[e.get("generateValue") for s in svcs if s["name"]=="sure-web" for e in s["envVars"] if e["key"]=="MCP_API_TOKEN"] == [True]')" = "true" ]
    [ "$(q "$f" '[e.get("sync") for s in svcs if s["name"]=="sure-web" for e in s["envVars"] if e["key"]=="MCP_USER_EMAIL"] == [False]')" = "true" ]
  done
}

@test "the self-hosted SSL settings are on for Sure services" {
  for f in "${REPO_ROOT}"/branches/*/render.yaml; do
    for key in SELF_HOSTED RAILS_FORCE_SSL RAILS_ASSUME_SSL; do
      [ "$(q "$f" "sorted({e.get('value') for s in svcs if s['name'] in ('sure-web','sure-worker') for e in s['envVars'] if e['key']=='$key'})")" = "true" ] || { echo "$f $key"; false; }
    done
  done
}
