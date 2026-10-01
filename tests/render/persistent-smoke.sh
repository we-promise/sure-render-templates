#!/usr/bin/env bash
# Authenticated HTTP smoke for an explicitly selected persistent sample app.
# Creates one isolated synthetic household; never provisions, seeds or deletes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${E2E_SAMPLE_URL:?Set the approved persistent sample app URL}"
[ "${E2E_CONFIRM_SAMPLE_DATA:-}" = yes ] || {
  echo 'Set E2E_CONFIRM_SAMPLE_DATA=yes to authorize synthetic records and two real AI chat requests.' >&2
  exit 1
}
[ "${E2E_ADMIN_ESTABLISHED:-}" = yes ] || {
  echo 'Set E2E_ADMIN_ESTABLISHED=yes only after the intended administrator exists.' >&2
  exit 1
}
python3 - "$E2E_SAMPLE_URL" <<'PY'
import sys
from urllib.parse import urlsplit
u = urlsplit(sys.argv[1])
if u.scheme != 'https' or not u.hostname or u.username or u.password or u.path not in ('', '/') or u.query or u.fragment:
    sys.exit('E2E_SAMPLE_URL must be a plain HTTPS origin without credentials, query or path')
PY
python3 "$ROOT/tests/lib/smoke.py" "${E2E_SAMPLE_URL%/}" --ai
