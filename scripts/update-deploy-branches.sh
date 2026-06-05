#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
CURRENT_BRANCH="$(git branch --show-current)"
BRANCHES=(sure-no-ai sure-simple-ai sure-external-ai)

if [[ -z "${CURRENT_BRANCH}" ]]; then
  echo "Run this script from a named branch, not a detached HEAD." >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Commit or stash your working tree changes before updating deploy branches." >&2
  exit 1
fi

for branch in "${BRANCHES[@]}"; do
  git checkout -B "${branch}" "${CURRENT_BRANCH}"
  cp "${ROOT_DIR}/branches/${branch}/render.yaml" "${ROOT_DIR}/render.yaml"

  if [[ "${branch}" != "sure-external-ai" ]]; then
    rm -f "${ROOT_DIR}/Dockerfile" "${ROOT_DIR}/package.json" "${ROOT_DIR}/package-lock.json"
  fi

  git add -A
  if git diff --cached --quiet; then
    echo "${branch}: no changes to commit"
  else
    git commit -m "Set up ${branch} Render Blueprint"
  fi
done

git checkout "${CURRENT_BRANCH}"

echo "Updated deploy branches: ${BRANCHES[*]}"
echo "Push them with: git push origin ${BRANCHES[*]}"
