#!/bin/sh
# Seed AlphaClaw's config so the OpenAI-compatible proxy (/v1/*) is enabled on
# first boot: alphaclaw 0.9.18 defaults features.openaiCompatApi to disabled
# (404 on /v1/chat/completions), and Sure calls that endpoint right after
# deploy. An existing config is left untouched, so a Setup UI toggle still wins.
set -e

CFG_DIR="${ALPHACLAW_ROOT_DIR:-$HOME/.alphaclaw}/.openclaw"
CFG="${CFG_DIR}/alphaclaw.json"

if [ ! -f "${CFG}" ]; then
  mkdir -p "${CFG_DIR}"
  printf '{\n  "features": {\n    "openaiCompatApi": {\n      "enabled": true\n    }\n  }\n}\n' > "${CFG}"
fi

exec /usr/bin/tini -- alphaclaw start
