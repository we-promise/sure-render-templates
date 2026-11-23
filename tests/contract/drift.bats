#!/usr/bin/env bats
# The deploy branches are generated artifacts. If someone changes branches/
# on main but forgets to run scripts/update-deploy-branches.sh and push, the
# Deploy buttons silently ship the old Blueprint. This suite catches that.
#
# Two layers:
# - Every run validates that generation succeeds locally from the current
#   source and produces the expected branch contents.
# - Outside pull_request CI (main pushes, local runs) it also compares the
#   LIVE branches against that expected content, so a merged template change
#   that was never published fails here. PRs are exempt from the live
#   comparison on purpose: publishing regenerated branches is
#   deployment-affecting (Render Blueprint Auto Sync) and is decided at merge
#   time, so a template-changing PR validates generation locally instead of
#   staying red until its unmerged changes are published.
#
# The live comparison needs the deploy branches fetched:
#   git fetch origin '+refs/heads/sure-*:refs/remotes/origin/sure-*'

load ../lib/common

on_pr_ci() { [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; }

@test "deploy branch generation succeeds from the current source" {
  scratch="$(mktemp -d)"
  git clone -q --no-checkout "${REPO_ROOT}" "$scratch/repo"
  git -C "$scratch/repo" config user.email "drift-check@example.invalid"
  git -C "$scratch/repo" config user.name "drift-check"
  git -C "$scratch/repo" checkout -q -B drift-check "$(git -C "${REPO_ROOT}" rev-parse HEAD)"
  (cd "$scratch/repo" && ./scripts/update-deploy-branches.sh >/dev/null)
  for b in "${DEPLOY_BRANCHES[@]}"; do
    diff <(git -C "$scratch/repo" show "$b:render.yaml") <(expected_render_yaml "$b") \
      || { echo "GENERATION: $b render.yaml differs from branches/$(flavor_of "$b")/render.yaml (tag $(tag_of "$b"))"; false; }
  done
  for b in sure-external-ai sure-external-ai-latest; do
    for f in Dockerfile package.json package-lock.json docker-entrypoint.sh; do
      diff <(git -C "$scratch/repo" show "$b:$f") "${REPO_ROOT}/$f" \
        || { echo "GENERATION: $b:$f missing or stale"; false; }
    done
  done
  rm -rf "$scratch"
}

@test "all 6 deploy branches are fetched (never pass on a missing ref)" {
  on_pr_ci && skip "live drift is enforced on main pushes; PRs validate generation locally"
  for b in "${DEPLOY_BRANCHES[@]}"; do
    git -C "${REPO_ROOT}" rev-parse --verify -q "$(remote_ref "$b")" >/dev/null || { echo "missing $(remote_ref "$b")"; false; }
  done
}

@test "each deploy branch's render.yaml matches what the generator would produce" {
  on_pr_ci && skip "live drift is enforced on main pushes; PRs validate generation locally"
  for b in "${DEPLOY_BRANCHES[@]}"; do
    diff <(git -C "${REPO_ROOT}" show "$(remote_ref "$b"):render.yaml") <(expected_render_yaml "$b") \
      || { echo "DRIFT: $b render.yaml differs from branches/$(flavor_of "$b")/render.yaml (tag $(tag_of "$b")). Run scripts/update-deploy-branches.sh and push."; false; }
  done
}

@test "external-ai deploy branches carry main's AlphaClaw build files" {
  on_pr_ci && skip "live drift is enforced on main pushes; PRs validate generation locally"
  for b in sure-external-ai sure-external-ai-latest; do
    for f in Dockerfile package.json package-lock.json docker-entrypoint.sh; do
      diff <(git -C "${REPO_ROOT}" show "$(remote_ref "$b"):$f") "${REPO_ROOT}/$f" \
        || { echo "DRIFT: $b:$f"; false; }
    done
  done
}
