#!/usr/bin/env bash
# Validate every deploy branch's render.yaml with Render's Blueprint validate
# API. Creates nothing and costs nothing. Fails if any Blueprint is invalid.
#   tests/render/validate.sh [branch...]   (default: all 6 deploy branches)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/render/lib.sh
source "$ROOT/tests/render/lib.sh"

branches=("$@")
[ ${#branches[@]} -gt 0 ] || branches=(sure-no-ai sure-no-ai-latest sure-simple-ai sure-simple-ai-latest sure-external-ai sure-external-ai-latest)
owner="$(owner_id)"
fail=0
for b in "${branches[@]}"; do
  f="$(mktemp --suffix=.yaml)"
  git -C "$ROOT" show "refs/remotes/origin/$b:render.yaml" > "$f"
  resp="$(curl -sS -X POST "${RENDER_API}/blueprints/validate" \
    -H "Authorization: Bearer ${RENDER_API_KEY}" -H 'Accept: application/json' \
    -F "ownerId=${owner}" -F "file=@${f};type=application/x-yaml")"
  rm -f "$f"
  if [ "$(jq -r '.valid' <<<"$resp")" = "true" ]; then
    log "valid   $b: $(jq -c '.plan // {}' <<<"$resp")"
  else
    log "INVALID $b: $(jq -c '.errors // .' <<<"$resp")"
    fail=1
  fi
done
exit "$fail"
