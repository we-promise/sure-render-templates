#!/usr/bin/env bash
# Regenerate the deploy branches from the per-flavor Blueprint templates in
# branches/. Each flavor gets two branches:
#   <flavor>         -> pins ghcr.io/we-promise/sure:stable
#   <flavor>-latest  -> pins ghcr.io/we-promise/sure:latest
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
CURRENT_BRANCH="$(git branch --show-current)"
FLAVORS=(sure-no-ai sure-simple-ai sure-external-ai)
TAGS=(stable latest)
OUT_BRANCHES=()

if [[ -z "${CURRENT_BRANCH}" ]]; then
  echo "Run this script from a named branch, not a detached HEAD." >&2
  exit 1
fi

trap 'git checkout "${CURRENT_BRANCH}" >/dev/null 2>&1 || true' EXIT

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash your working tree changes before updating deploy branches." >&2
  exit 1
fi

for flavor in "${FLAVORS[@]}"; do
  for tag in "${TAGS[@]}"; do
    branch="${flavor}"
    if [[ "${tag}" == "latest" ]]; then
      branch="${flavor}-latest"
    fi
    OUT_BRANCHES+=("${branch}")

    git checkout -B "${branch}" "${CURRENT_BRANCH}"
    cp "${ROOT_DIR}/branches/${flavor}/render.yaml" "${ROOT_DIR}/render.yaml"
    sed -i.bak -E "s#(ghcr\.io/we-promise/sure:)(stable|latest)#\1${tag}#g" "${ROOT_DIR}/render.yaml"
    rm -f "${ROOT_DIR}/render.yaml.bak"

    if [[ "${flavor}" != "sure-external-ai" ]]; then
      rm -f "${ROOT_DIR}/Dockerfile" "${ROOT_DIR}/package.json" "${ROOT_DIR}/package-lock.json"
    fi

    git add -u
    if git diff --cached --quiet; then
      echo "${branch}: no changes to commit"
    else
      git commit -m "Set up ${branch} Render Blueprint (image tag: ${tag})"
    fi
  done
done

git checkout "${CURRENT_BRANCH}"
trap - EXIT

echo "Updated deploy branches: ${OUT_BRANCHES[*]}"
echo "Push them with: git push --force-with-lease origin ${OUT_BRANCHES[*]}"
