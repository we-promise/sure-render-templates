#!/usr/bin/env bash
# Local test runner.
#   tests/run.sh            unit + contract (fast, no docker)
#   tests/run.sh unit|contract|e2e|all
set -euo pipefail
cd "$(dirname "$0")/.."

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need bats
need python3
python3 -c 'import yaml' 2>/dev/null || { echo "missing: python3 PyYAML (pip install pyyaml)" >&2; exit 1; }

fetch_deploy_branches() {
  git fetch -q origin '+refs/heads/sure-*:refs/remotes/origin/sure-*'
}

case "${1:-fast}" in
  unit) bats tests/unit ;;
  contract) fetch_deploy_branches; bats tests/contract ;;
  fast) fetch_deploy_branches; bats tests/unit tests/contract ;;
  e2e) need docker; need curl; fetch_deploy_branches; bats tests/e2e ;;
  all) need docker; need curl; fetch_deploy_branches; bats tests/unit tests/contract tests/e2e ;;
  *) echo "usage: $0 [unit|contract|fast|e2e|all]" >&2; exit 2 ;;
esac
