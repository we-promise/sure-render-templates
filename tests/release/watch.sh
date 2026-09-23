#!/usr/bin/env bash
# Look for new we-promise/sure builds and start the matching release test,
# once per build. Run every 6 hours by .github/workflows/release-watch.yml.
#
#   newest non-prerelease release (v0.7.4, v0.7.1-hotfix.1, ...) -> channel stable
#   newest *-alpha* prerelease    (v0.7.5-alpha.10, ...)         -> channel latest
#   current ghcr :nightly digest  (not a GitHub Release)         -> channel nightly
#
# That mirrors Sure's publish.yml: v*-alpha* tags become ghcr :latest, every
# other v* tag becomes :stable, and the GitHub Release is only created after
# the image is pushed. Nightlies come from Sure's nightly cron and are only
# an image tag, so they are tracked by digest. A build counts as tested once any "release test"
# run exists for it (pass or fail), so a red run stays red instead of being
# retried every 6 hours.
#
#   GH_TOKEN       token with actions:write on this repo (github.token in CI)
#   SURE_REPO      default we-promise/sure
#   DRY_RUN=1      print what would be dispatched, dispatch nothing
#   RELEASES_FILE  read releases JSON from a file instead of the API (tests)
#   RUNS_FILE      read existing run titles (one per line) from a file (tests)
#   NIGHTLY_DIGEST use this digest instead of asking ghcr (tests)
set -euo pipefail

SURE_REPO="${SURE_REPO:-we-promise/sure}"
WORKFLOW=release-test.yml

releases() {
  if [ -n "${RELEASES_FILE:-}" ]; then cat "$RELEASES_FILE"
  else gh api "repos/${SURE_REPO}/releases?per_page=50"; fi
}

run_titles() {
  if [ -n "${RUNS_FILE:-}" ]; then cat "$RUNS_FILE"
  else gh run list --workflow "$WORKFLOW" --limit 200 --json displayTitle --jq '.[].displayTitle'; fi
}

json="$(releases)"
# The API lists newest first. Drafts are never shipped.
stable="$(jq -r '[.[] | select(.draft|not) | select(.prerelease|not)][0].tag_name // empty' <<<"$json")"
alpha="$(jq -r '[.[] | select(.draft|not) | select(.prerelease) | select(.tag_name|test("-alpha"))][0].tag_name // empty' <<<"$json")"
titles="$(run_titles)"

nightly_digest() {
  if [ -n "${NIGHTLY_DIGEST+x}" ]; then printf '%s' "$NIGHTLY_DIGEST"; return; fi
  local token
  token="$(curl -fsS "https://ghcr.io/token?scope=repository:${SURE_REPO}:pull" | jq -r .token)"
  curl -fsSI -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://ghcr.io/v2/${SURE_REPO}/manifests/nightly" \
    | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:" {print $2}'
}
nightly="$(nightly_digest)"

check() {
  local channel="$1" tag="$2" title
  if [ -z "$tag" ]; then echo "no ${channel} release found"; return; fi
  title="release test ${channel} ${tag}"
  if grep -Fxq "$title" <<<"$titles"; then
    echo "already tested: ${channel} ${tag}"
    return
  fi
  echo "dispatch: ${channel} ${tag}"
  [ -n "${DRY_RUN:-}" ] || gh workflow run "$WORKFLOW" -f channel="$channel" -f sure_tag="$tag"
}

check stable "$stable"
check latest "$alpha"
check nightly "$nightly"
