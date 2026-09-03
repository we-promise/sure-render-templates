#!/usr/bin/env bash
# Switch the Sure image tag between "stable" and "latest" in every
# render.yaml in this repo (the root Blueprint and branches/*/render.yaml).
#
# Render Blueprint files do not support variable interpolation, so the image
# tag must be a literal string in the YAML. This script rewrites it.
#
# Usage:
#   scripts/use-image-tag.sh stable   # pin ghcr.io/we-promise/sure:stable (default)
#   scripts/use-image-tag.sh latest   # track ghcr.io/we-promise/sure:latest
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
TAG="${1:-}"

if [[ "${TAG}" != "stable" && "${TAG}" != "latest" ]]; then
  echo "usage: $0 [stable|latest]" >&2
  exit 1
fi

FILES=("${ROOT_DIR}/render.yaml")
for f in "${ROOT_DIR}"/branches/*/render.yaml; do
  [[ -f "${f}" ]] && FILES+=("${f}")
done

for f in "${FILES[@]}"; do
  sed -i.bak -E "s#(url: ghcr\.io/we-promise/sure:)(stable|latest)#\1${TAG}#g" "${f}"
  rm -f "${f}.bak"
  echo "${f#"${ROOT_DIR}"/}:"
  grep -n "ghcr.io/we-promise/sure" "${f}" | sed 's/^/  /'
done
