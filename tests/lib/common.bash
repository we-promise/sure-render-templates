# Shared helpers for the bats suites.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BPQ="python3 ${REPO_ROOT}/tests/lib/bpq.py"
FLAVORS=(sure-no-ai sure-simple-ai sure-external-ai)
DEPLOY_BRANCHES=(sure-no-ai sure-no-ai-latest sure-simple-ai sure-simple-ai-latest sure-external-ai sure-external-ai-latest)

# flavor_of <deploy-branch> / tag_of <deploy-branch>
flavor_of() { echo "${1%-latest}"; }
tag_of() { if [[ "$1" == *-latest ]]; then echo latest; else echo stable; fi; }

# The render.yaml a deploy branch *should* contain, derived exactly the way
# scripts/update-deploy-branches.sh derives it.
expected_render_yaml() {
  sed -E "s#(url: ghcr\.io/we-promise/sure:)(stable|latest)#\1$(tag_of "$1")#g" \
    "${REPO_ROOT}/branches/$(flavor_of "$1")/render.yaml"
}

# Remote ref for a deploy branch; CI fetches them into refs/remotes/origin.
remote_ref() { echo "refs/remotes/origin/$1"; }
