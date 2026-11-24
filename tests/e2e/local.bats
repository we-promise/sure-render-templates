#!/usr/bin/env bats
# Local e2e: boot a deploy branch's Blueprint in docker compose and prove it
# works the way it would on Render. The compose file is generated from the
# branch's own render.yaml (tests/lib/blueprint.py), so env vars, image tag,
# disk and worker command can't drift from what users deploy.
#
# Which branch content boots:
# - pull_request CI generates the deploy branches from the checked-out
#   (proposed) source in a scratch clone and boots that, so a template-
#   changing PR tests its own Blueprint instead of the live branches it has
#   not published yet.
# - main pushes and local runs boot the LIVE branches (refs/remotes/origin),
#   so a merged template change that was never published fails here.
#
#   E2E_BRANCH   deploy branch to test (default: sure-no-ai)
#   E2E_WEB_PORT host port for sure-web (default: 3000)
#   E2E_MEM_LIMIT optional memory cap for web, worker and AlphaClaw, e.g. 512m
#                (Render's default for new services); unset means no cap
#   E2E_IMAGE    optional Sure image to run instead of the branch's pin, e.g.
#                ghcr.io/we-promise/sure@sha256:... for a nightly build
#   E2E_OPENAI_STUB=1     add a test OpenAI-compatible endpoint to the compose
#                         project (automatic for the sure-simple-ai branches)
#   E2E_OPENAI_ACCESS_TOKEN / E2E_OPENAI_MODEL
#                the token/model the stub requires and the services send
#                (defaults: e2e-openai-token / e2e-test-model)
#
# Needs docker (with compose v2), curl, python3 + PyYAML, and the deploy
# branch fetched into refs/remotes/origin.

load ../lib/common

BOOT_TIMEOUT="${E2E_BOOT_TIMEOUT:-600}"

setup_file() {
  export E2E_BRANCH="${E2E_BRANCH:-sure-no-ai}"
  export E2E_WEB_PORT="${E2E_WEB_PORT:-3000}"
  export E2E_DIR="$(mktemp -d)"
  export COMPOSE_PROJECT_NAME="sure-e2e-$$"
  # blueprint.py suffixes service names the way Render can (sure-web-2clo).
  export WEB=sure-web-e2e WORKER=sure-worker-e2e ALPHACLAW=alphaclaw-e2e
  # The whole branch, so docker-runtime services (AlphaClaw) build from it.
  if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
    E2E_GEN_DIR="$(mktemp -d)"; export E2E_GEN_DIR
    git clone -q --no-checkout "${REPO_ROOT}" "$E2E_GEN_DIR/repo"
    git -C "$E2E_GEN_DIR/repo" config user.email "e2e-gen@example.invalid"
    git -C "$E2E_GEN_DIR/repo" config user.name "e2e-gen"
    git -C "$E2E_GEN_DIR/repo" checkout -q -B e2e-src "$(git -C "${REPO_ROOT}" rev-parse HEAD)"
    (cd "$E2E_GEN_DIR/repo" && ./scripts/update-deploy-branches.sh >/dev/null)
    export E2E_SRC_REPO="$E2E_GEN_DIR/repo" E2E_SRC_REF="$E2E_BRANCH"
  else
    E2E_SRC_REF="$(remote_ref "$E2E_BRANCH")"
    export E2E_SRC_REPO="${REPO_ROOT}" E2E_SRC_REF
  fi
  git -C "${E2E_SRC_REPO}" archive "$E2E_SRC_REF" | tar -xf - -C "${E2E_DIR}"
  if is_external_ai; then
    # Values Render prompts for. AlphaClaw only needs the GitHub ones during
    # its first-run setup, which this test doesn't run.
    export E2E_PROMPT_SETUP_PASSWORD="${E2E_PROMPT_SETUP_PASSWORD:-$(openssl rand -hex 16)}"
    export E2E_PROMPT_GITHUB_TOKEN="${E2E_PROMPT_GITHUB_TOKEN:-unused-by-e2e}"
    export E2E_PROMPT_GITHUB_WORKSPACE_REPO="${E2E_PROMPT_GITHUB_WORKSPACE_REPO:-example/unused-by-e2e}"
    # The demo user, created by the demo data test below.
    export E2E_PROMPT_MCP_USER_EMAIL="${E2E_PROMPT_MCP_USER_EMAIL:-user@example.com}"
  fi
  if is_simple_ai; then
    # Simple AI keeps OpenAI settings out of the Blueprint (Render environment
    # groups supply them), so the harness runs its own test model endpoint and
    # points both services at it. See tests/lib/stubs/openai_stub.py.
    export E2E_OPENAI_STUB=1
    export E2E_OPENAI_ACCESS_TOKEN="${E2E_OPENAI_ACCESS_TOKEN:-e2e-openai-token}"
    export E2E_OPENAI_MODEL="${E2E_OPENAI_MODEL:-e2e-test-model}"
  fi
  if [ -n "${E2E_IMAGE:-}" ]; then
    sed -i -E "s#(url: )ghcr\.io/we-promise/sure[:@][^[:space:]]+#\1${E2E_IMAGE}#" "${E2E_DIR}/render.yaml"
  fi
  python3 "${REPO_ROOT}/tests/lib/blueprint.py" compose "${E2E_DIR}/render.yaml" > "${E2E_DIR}/compose.yaml"
  export DC="docker compose -f ${E2E_DIR}/compose.yaml"
  $DC up -d --quiet-pull --build
  # Wait for Rails (db:prepare runs in the web entrypoint before the server).
  local deadline=$((SECONDS + BOOT_TIMEOUT))
  until curl -fsS -o /dev/null -H 'X-Forwarded-Proto: https' "http://127.0.0.1:${E2E_WEB_PORT}/up"; do
    if (( SECONDS > deadline )); then
      $DC ps -a >&3; $DC logs --tail 80 >&3
      echo "sure-web never answered /up within ${BOOT_TIMEOUT}s" >&3
      return 1
    fi
    sleep 5
  done
}

teardown_file() {
  if [ -n "${DC:-}" ]; then
    # Always keep a log tail for CI annotations / debugging.
    $DC ps -a > "${E2E_LOG_FILE:-/tmp/sure-e2e-logs.txt}" 2>&1 || true
    $DC logs --no-color --tail 120 >> "${E2E_LOG_FILE:-/tmp/sure-e2e-logs.txt}" 2>&1 || true
    $DC down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf "${E2E_DIR:-/nonexistent}" "${E2E_GEN_DIR:-/nonexistent}"
}

redis() { $DC exec -T redis redis-cli "$@"; }

is_external_ai() { [ "$(flavor_of "$E2E_BRANCH")" = sure-external-ai ]; }
is_simple_ai() { [ "$(flavor_of "$E2E_BRANCH")" = sure-simple-ai ]; }

# An env var as AlphaClaw's main process sees it (its entrypoint builds
# values that `docker compose exec` would not inherit).
proc1_env() { $DC exec -T "$1" sh -c "tr '\\0' '\\n' < /proc/1/environ" | sed -n "s/^$2=//p"; }

# The part of a service's Blueprint dockerCommand before its final exec: the
# environment setup it does. Empty for a plain command; fails loudly on a
# missing service or an sh -c script without exec.
command_prefix() {
  python3 -c 'import shlex, sys, yaml
bp = yaml.safe_load(open(sys.argv[1]))
svc = [s for s in bp["services"] if s["name"] == sys.argv[2]]
if not svc:
    sys.exit(f"no service {sys.argv[2]!r} in the Blueprint")
args = shlex.split(svc[0].get("dockerCommand") or "")
if args[:2] not in (["/bin/sh", "-c"], ["sh", "-c"]):
    sys.exit(0)
if "exec " not in args[2]:
    sys.exit(f"{sys.argv[2]}: sh -c dockerCommand has no exec: {args[2]!r}")
print(args[2].split("exec ", 1)[0], end="")' "${E2E_DIR}/render.yaml" "$1"
}

# An env var as a service's Blueprint dockerCommand builds it: the command's
# script with its final exec swapped for printenv. Puma and Sidekiq rewrite
# their process title over /proc/1/environ, so it can't be read there.
command_env() { $DC exec -T "$1-e2e" sh -c "$(command_prefix "$1")exec printenv $2"; }

# Sends one chat message through Sure's own external assistant client, in the
# environment the service's start command builds, and prints the outcome.
# $2 overrides the token. Telemetry is off for this process so CI runs don't
# report assistant usage.
sure_chat() {
  local ruby='cfg = Assistant::External.config
abort "E2E_RESULT not configured: url=#{cfg.url.inspect}" unless Assistant::External.configured?
token = ENV["E2E_TOKEN"].presence || cfg.token
client = Assistant::External::Client.new(url: cfg.url, token: token, model: cfg.model, agent_id: cfg.agent_id, session_key: cfg.session_key)
begin
  client.chat(messages: [ { role: "user", content: "ping" } ]) { |chunk| }
  puts "E2E_RESULT ok"
rescue Assistant::Error => e
  puts "E2E_RESULT #{e.message}"
end'
  local prefix log="${BATS_TEST_TMPDIR}/sure_chat-$1.log"
  prefix="$(command_prefix "$1")" || return 1
  # A one-off container with the service's configuration, so a second Rails
  # process doesn't share (or, under E2E_MEM_LIMIT, skew) the service's memory.
  $DC run --rm --no-deps -T -e POSTHOG_FEEDBACK_ENABLED=false -e E2E_TOKEN="${2:-}" --entrypoint sh "$1-e2e" \
    -c "${prefix}exec ./bin/rails runner \"\$1\"" _ "$ruby" > "$log" 2>&1
  sed -n 's/^E2E_RESULT //p' "$log"
}

# The end of sure_chat's full output, for failure messages.
sure_chat_log() { tail -n 25 "${BATS_TEST_TMPDIR}/sure_chat-$1.log" 2>/dev/null; }

# Sends one chat message through Sure's builtin OpenAI provider, in the
# environment the service's start command builds, and prints the reply or the
# provider's error. $2 overrides the configured access token.
simple_chat() {
  local ruby='provider = Provider::Registry.get_provider(:openai)
abort "E2E_RESULT not configured" unless provider
response = provider.chat_response("ping", model: ENV["OPENAI_MODEL"].presence || Provider::Openai.effective_model)
if response.success?
  puts "E2E_RESULT ok: #{response.data.messages.map(&:output_text).join}"
else
  puts "E2E_RESULT #{response.error.message}"
end'
  local prefix log="${BATS_TEST_TMPDIR}/simple_chat-$1.log"
  prefix="$(command_prefix "$1")" || return 1
  # A one-off container with the service's configuration, so a second Rails
  # process doesn't share (or, under E2E_MEM_LIMIT, skew) the service's memory.
  $DC run --rm --no-deps -T -e POSTHOG_FEEDBACK_ENABLED=false -e OPENAI_ACCESS_TOKEN="${2:-${E2E_OPENAI_ACCESS_TOKEN}}" --entrypoint sh "$1-e2e" \
    -c "${prefix}exec ./bin/rails runner \"\$1\"" _ "$ruby" > "$log" 2>&1
  sed -n 's/^E2E_RESULT //p' "$log"
}

# The end of simple_chat's full output, for failure messages.
simple_chat_log() { tail -n 25 "${BATS_TEST_TMPDIR}/simple_chat-$1.log" 2>/dev/null; }

@test "compose runs the image tag the branch pins (or E2E_IMAGE)" {
  want="${E2E_IMAGE:-ghcr.io/we-promise/sure:$(tag_of "$E2E_BRANCH")}"
  run bash -c "$DC config --images | sort -u | grep we-promise/sure"
  [ "$output" = "$want" ]
}

@test "web and worker are running, not restart-looping" {
  svcs=("$WEB" "$WORKER"); is_external_ai && svcs+=("$ALPHACLAW")
  for svc in "${svcs[@]}"; do
    state="$($DC ps --format '{{.State}}' "$svc")"
    [ "$state" = "running" ] || { echo "$svc state=$state"; false; }
  done
}

@test "database is fully migrated" {
  run $DC exec -T "$WEB" ./bin/rails runner 'exit(ActiveRecord::Base.connection_pool.migration_context.needs_migration? ? 1 : 0)'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "app runs as behind a TLS proxy: https links and HSTS even on plain http" {
  # Sure defaults RAILS_ASSUME_SSL=true and RAILS_FORCE_SSL=true (Render terminates
  # TLS), so plain http is not redirected; it is treated as https instead.
  run curl -s -D - -o /dev/null "http://127.0.0.1:${E2E_WEB_PORT}/"
  grep -qi '^strict-transport-security:' <<<"$output" || { echo "$output"; false; }
  loc="$(grep -i '^location:' <<<"$output" | tr -d '\r' | awk '{print $2}')"
  [ -z "$loc" ] || [[ "$loc" == https://* ]] || { echo "$output"; false; }
}

@test "smoke: sign up, log in, onboarding, account + expense, worker sync (Render-style proxy header)" {
  run python3 "${REPO_ROOT}/tests/lib/smoke.py" "http://127.0.0.1:${E2E_WEB_PORT}" --forwarded-proto https
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "Sidekiq worker is registered in Redis" {
  deadline=$((SECONDS + 120))
  until [ "$(redis SCARD processes)" -ge 1 ] 2>/dev/null; do
    (( SECONDS < deadline )) || { $DC logs --tail 40 "$WORKER"; false; }
    sleep 3
  done
}

@test "a job enqueued by web is processed by the worker" {
  before="$(redis GET stat:processed)"; before="${before:-0}"
  # SyncCleanerJob is Sure's hourly housekeeping job; on a fresh DB it is a no-op.
  run $DC exec -T "$WEB" ./bin/rails runner 'SyncCleanerJob.perform_later'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  deadline=$((SECONDS + 120))
  while :; do
    now="$(redis GET stat:processed)"; now="${now:-0}"
    (( now > before )) && break
    (( SECONDS < deadline )) || { echo "stat:processed stayed at $now"; $DC logs --tail 40 "$WORKER"; false; }
    sleep 3
  done
}

@test "demo data loads the README way and the demo user sees it" {
  # README: "Optionally, load demo data: rake demo_data:default", then log in as
  # user@example.com / Password1!. Run inside the web container like a self-hoster would.
  # Rails logs to stdout; keep stderr (where rake reports the error) apart.
  run timeout 1200 $DC exec -T "$WEB" sh -c 'bundle exec rake demo_data:default 2>/tmp/demo-data.err'
  if [ "$status" -ne 0 ]; then
    echo "$output" | head -1                                   # includes the seed
    $DC exec -T "$WEB" sh -c 'grep -v "^/usr/local/bundle" /tmp/demo-data.err | head -25' || true
    false
  fi
  echo "$output" | head -1
  echo "$output" | tail -8
  run python3 "${REPO_ROOT}/tests/lib/smoke.py" "http://127.0.0.1:${E2E_WEB_PORT}" --forwarded-proto https --demo
  echo "$output"
  [ "$status" -eq 0 ]
}

# Registered only for the external AI profile, so other profiles don't show skips.
if [[ "${E2E_BRANCH:-sure-no-ai}" == sure-external-ai* ]]; then

@test "external AI: Sure's assistant client reaches AlphaClaw with the shared token, from web and worker (no model call)" {
  # Chat replies run in Sidekiq, so the worker's start command must build the
  # same configuration as web's.
  url="$(command_env sure-web EXTERNAL_ASSISTANT_URL)"
  [ "$(command_env sure-worker EXTERNAL_ASSISTANT_URL)" = "$url" ] || { echo "web and worker build different URLs"; false; }
  deadline=$((SECONDS + 300))
  until [ "$(sure_chat sure-web wrong-token)" = "External assistant returned HTTP 401." ]; do
    (( SECONDS < deadline )) || { echo "EXTERNAL_ASSISTANT_URL=$url, wrong token:"; sure_chat_log sure-web; $DC logs --tail 40 "$ALPHACLAW"; false; }
    sleep 5
  done
  # With the right token AlphaClaw forwards to its OpenClaw gateway, which
  # starts only after first-run setup. That setup needs GitHub and a model
  # provider and isn't run here, so 502 is the expected end state.
  for svc in sure-web sure-worker; do
    run sure_chat "$svc"
    [ "$output" = "External assistant returned HTTP 502." ] || { echo "$svc: $output"; sure_chat_log "$svc"; false; }
  done
  # AlphaClaw's own answers behind those statuses, so another 401 or 502 can't pass.
  token="$($DC exec -T "$WEB" printenv EXTERNAL_ASSISTANT_TOKEN)"
  alphaclaw() { $DC exec -T "$WEB" curl -s -m 20 -H 'Content-Type: application/json' "$@" -d '{"model":"openclaw","messages":[]}' "$url"; }
  run alphaclaw
  [ "$output" = '{"error":"Unauthorized"}' ] || { echo "no token: $output"; false; }
  run alphaclaw -H "Authorization: Bearer wrong-token"
  [ "$output" = '{"error":"Unauthorized"}' ] || { echo "wrong token: $output"; false; }
  run alphaclaw -H "Authorization: Bearer $token"
  [ "$output" = '{"error":"Gateway unavailable"}' ] || { echo "shared token: $output"; false; }
}

@test "external AI: AlphaClaw's image can verify HTTPS servers (CA bundle present)" {
  run $DC exec -T "$ALPHACLAW" sh -c 'test -s /etc/ssl/certs/ca-certificates.crt'
  [ "$status" -eq 0 ] || { echo "no CA bundle: curl and git over HTTPS fail at boot"; false; }
}

@test "external AI: from AlphaClaw, its MCP URL and token list Sure's tools" {
  url="$(proc1_env "$ALPHACLAW" REMOTE_MCP_URL)"
  echo "REMOTE_MCP_URL=$url"
  # Runs as the demo user (MCP_USER_EMAIL), so it follows the demo data test.
  run $DC exec -T "$ALPHACLAW" node -e '
    const [url, token] = process.argv.slice(1);
    const call = (id, method, params = {}) => fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream", Authorization: `Bearer ${token}` },
      body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
    }).then(async (r) => { if (!r.ok) throw new Error(`${method}: HTTP ${r.status} ${await r.text()}`); return r.json(); });
    (async () => {
      await call(1, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "e2e", version: "1" } });
      const tools = (await call(2, "tools/list")).result.tools.map((t) => t.name);
      console.log(tools.join(" "));
      if (!tools.includes("get_accounts")) process.exit(1);
    })().catch((e) => { console.error(e.message); process.exit(1); });
  ' "$url" "$(proc1_env "$ALPHACLAW" REMOTE_MCP_API_TOKEN)"
  echo "$output"
  [ "$status" -eq 0 ]
}

fi

# Registered only for the simple AI profile, so other profiles don't show skips.
if [[ "${E2E_BRANCH:-sure-no-ai}" == sure-simple-ai* ]]; then

@test "simple AI: Sure's OpenAI provider reaches the test model endpoint with the shared token, from web and worker" {
  # Chat replies run in Sidekiq, so the worker's start command must build the
  # same configuration as web's.
  for key in OPENAI_ACCESS_TOKEN OPENAI_URI_BASE OPENAI_MODEL; do
    [ "$(command_env sure-web "$key")" = "$(command_env sure-worker "$key")" ] || { echo "web and worker build different $key"; false; }
  done
  url="$(command_env sure-web OPENAI_URI_BASE)/chat/completions"
  deadline=$((SECONDS + 300))
  until [ "$(simple_chat sure-web)" = "ok: pong from ${E2E_OPENAI_MODEL}" ]; do
    (( SECONDS < deadline )) || { echo "sure-web first chat:"; simple_chat_log sure-web; $DC logs --tail 40 openai-stub; false; }
    sleep 5
  done
  # With the wrong token the stub rejects the call, so a passing chat proves
  # the configured token is what each service sends.
  run simple_chat sure-web wrong-token
  [[ "$output" == *"401"* ]] || { echo "wrong token: $output"; simple_chat_log sure-web; false; }
  for svc in sure-web sure-worker; do
    run simple_chat "$svc"
    [ "$output" = "ok: pong from ${E2E_OPENAI_MODEL}" ] || { echo "$svc: $output"; simple_chat_log "$svc"; false; }
  done
  # The stub's own answers behind those statuses, so another 401 can't pass.
  stub_chat() { $DC exec -T "$WEB" curl -s -m 20 -H 'Content-Type: application/json' "$@" -d "{\"model\":\"$E2E_OPENAI_MODEL\",\"messages\":[]}" "$url"; }
  run stub_chat
  [[ "$output" == *"Incorrect API key"* ]] || { echo "no token: $output"; false; }
  run stub_chat -H "Authorization: Bearer wrong-token"
  [[ "$output" == *"Incorrect API key"* ]] || { echo "wrong token: $output"; false; }
  run stub_chat -H "Authorization: Bearer ${E2E_OPENAI_ACCESS_TOKEN}"
  [[ "$output" == *"\"content\":\"pong from ${E2E_OPENAI_MODEL}\""* ]] || { echo "shared token: $output"; false; }
}

fi
