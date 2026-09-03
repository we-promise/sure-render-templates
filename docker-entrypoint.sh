#!/bin/sh
# Seed AlphaClaw's config so the OpenAI-compatible proxy (/v1/*) is enabled on
# first boot: alphaclaw (verified through 0.9.34) defaults
# features.openaiCompatApi to disabled (404 on /v1/chat/completions), and Sure
# calls that endpoint right after deploy. The seed only applies when no config
# exists yet: onboarding's ensureGatewayProxyConfig then flips on the matching
# gateway endpoints (openclaw.json gateway.http.endpoints.*), and a Setup UI
# toggle still wins afterwards (UI writes merge, never clobber).
set -e

CFG_DIR="${ALPHACLAW_ROOT_DIR:-$HOME/.alphaclaw}/.openclaw"
CFG="${CFG_DIR}/alphaclaw.json"

if [ ! -f "${CFG}" ]; then
  mkdir -p "${CFG_DIR}"
  printf '{\n  "features": {\n    "openaiCompatApi": {\n      "enabled": true\n    }\n  }\n}\n' > "${CFG}"
fi

exec /usr/bin/tini -- alphaclaw start
