#!/usr/bin/env bats
# The deploy branches are generated artifacts. If someone changes branches/
# on main but forgets to run scripts/update-deploy-branches.sh and push, the
# Deploy buttons silently ship the old Blueprint. This suite catches that.
#
# Needs the deploy branches fetched: git fetch origin '+refs/heads/sure-*:refs/remotes/origin/sure-*'
# On a PR the check compares the PR's templates with the live branches, so a
# PR that changes branches/ is expected to fail here until the branches are
# regenerated; the failure message says which files differ.

load ../lib/common

@test "all 6 deploy branches are fetched (never pass on a missing ref)" {
  for b in "${DEPLOY_BRANCHES[@]}"; do
    git -C "${REPO_ROOT}" rev-parse --verify -q "$(remote_ref "$b")" >/dev/null || { echo "missing $(remote_ref "$b")"; false; }
  done
}

@test "each deploy branch's render.yaml matches what the generator would produce" {
  for b in "${DEPLOY_BRANCHES[@]}"; do
    diff <(git -C "${REPO_ROOT}" show "$(remote_ref "$b"):render.yaml") <(expected_render_yaml "$b") \
      || { echo "DRIFT: $b render.yaml differs from branches/$(flavor_of "$b")/render.yaml (tag $(tag_of "$b")). Run scripts/update-deploy-branches.sh and push."; false; }
  done
}

@test "external-ai deploy branches carry main's AlphaClaw build files" {
  for b in sure-external-ai sure-external-ai-latest; do
    for f in Dockerfile package.json package-lock.json docker-entrypoint.sh; do
      diff <(git -C "${REPO_ROOT}" show "$(remote_ref "$b"):$f") "${REPO_ROOT}/$f" \
        || { echo "DRIFT: $b:$f"; false; }
    done
  done
}
