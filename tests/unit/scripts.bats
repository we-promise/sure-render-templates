#!/usr/bin/env bats
# Unit tests for scripts/, run against throwaway clones of the working tree.

load ../lib/common

setup() {
  WORK="$(mktemp -d)"
  git clone -q "${REPO_ROOT}" "${WORK}/repo"
  cd "${WORK}/repo"
  # Carry uncommitted edits to scripts/ and branches/ into the clone so the
  # tests exercise the tree under test, not just HEAD.
  cp -R "${REPO_ROOT}/scripts" "${REPO_ROOT}/branches" "${REPO_ROOT}/render.yaml" .
  git -c user.name=t -c user.email=t@example.com commit -qam "tree under test" --allow-empty
  git checkout -q -B work
}

teardown() {
  rm -rf "${WORK}"
}

@test "use-image-tag.sh rejects a missing or unknown tag" {
  run scripts/use-image-tag.sh
  [ "$status" -ne 0 ]
  run scripts/use-image-tag.sh edge
  [ "$status" -ne 0 ]
}

@test "use-image-tag.sh latest rewrites every Sure image line and nothing else" {
  scripts/use-image-tag.sh stable >/dev/null
  git -c user.name=t -c user.email=t@example.com commit -qam "pin stable" --allow-empty
  run scripts/use-image-tag.sh latest
  [ "$status" -eq 0 ]
  run grep -rn 'url: ghcr.io/we-promise/sure:stable' render.yaml branches
  [ "$status" -ne 0 ]
  changed="$(git diff -U0 -- render.yaml branches | grep -E '^[-+] ')"
  [ -n "$changed" ]
  # Every changed line is a Sure image url line (comments untouched).
  run grep -vE '^[-+] +url: ghcr\.io/we-promise/sure:(stable|latest)$' <<<"$changed"
  [ "$status" -ne 0 ]
}

@test "use-image-tag.sh stable then latest round-trips" {
  run scripts/use-image-tag.sh stable
  [ "$status" -eq 0 ]
  run grep -rn 'url: ghcr.io/we-promise/sure:latest' render.yaml branches
  [ "$status" -ne 0 ]
  run scripts/use-image-tag.sh latest
  [ "$status" -eq 0 ]
  run grep -rn 'url: ghcr.io/we-promise/sure:stable' render.yaml branches
  [ "$status" -ne 0 ]
}

@test "update-deploy-branches.sh refuses a dirty tree" {
  echo dirty >> README.md
  run scripts/update-deploy-branches.sh
  [ "$status" -ne 0 ]
}

@test "update-deploy-branches.sh builds all 6 branches with the right root render.yaml" {
  run scripts/update-deploy-branches.sh
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = "work" ]
  for b in "${DEPLOY_BRANCHES[@]}"; do
    run git show "$b:render.yaml"
    [ "$status" -eq 0 ]
    diff <(git show "$b:render.yaml") <(expected_render_yaml "$b")
    tag="$(tag_of "$b")"
    run bash -c "git show '$b:render.yaml' | grep -c 'url: ghcr.io/we-promise/sure:$tag'"
    [ "$output" -ge 1 ]
  done
}

@test "update-deploy-branches.sh keeps the AlphaClaw build files only on external-ai branches" {
  run scripts/update-deploy-branches.sh
  [ "$status" -eq 0 ]
  for b in "${DEPLOY_BRANCHES[@]}"; do
    for f in Dockerfile package.json package-lock.json; do
      if [[ "$b" == sure-external-ai* ]]; then
        git cat-file -e "$b:$f"
      else
        run git cat-file -e "$b:$f"
        [ "$status" -ne 0 ]
      fi
    done
  done
}
