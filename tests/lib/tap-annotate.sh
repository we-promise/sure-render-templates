#!/usr/bin/env bash
# Turn failed bats tests in a TAP file into GitHub Actions error annotations,
# so a failure is readable from the PR's checks without opening the job log.
#   tests/lib/tap-annotate.sh <tap-file> [extra-log-file]
set -euo pipefail
tap="$1"; extra="${2:-}"
enc() { local s="$1"; s="${s//'%'/'%25'}"; s="${s//$'\r'/}"; s="${s//$'\n'/'%0A'}"; printf '%s' "$s"; }
awk '
  /^not ok / { if (msg != "") print msg "\x1e"; msg = $0; next }
  /^(ok |1\.\.)/ { if (msg != "") { print msg "\x1e"; msg = "" } next }
  { if (msg != "") msg = msg "\n" $0 }
  END { if (msg != "") print msg "\x1e" }
' "$tap" | while IFS= read -r -d $'\x1e' block; do
  block="${block#$'\n'}"
  title="$(head -n1 <<<"$block" | cut -c1-120)"
  echo "::error title=$(enc "$title")::$(enc "$(head -n 40 <<<"$block")")"
done
if [ -n "$extra" ] && [ -s "$extra" ]; then
  echo "::error title=container logs (tail)::$(enc "$(tail -n 60 "$extra")")"
fi
