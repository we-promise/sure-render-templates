#!/usr/bin/env bash
# Phase bookkeeping for the Render e2e: every required phase ends up with an
# explicit outcome (pass / fail / skipped / not run), and the run is only green
# when ALL of them pass. A failed phase does not stop phases that do not depend
# on it; a phase whose prerequisite did not pass is reported "skipped" with the
# reason, never as a pass.
#
#   phase_expect <name>...              declare the required phases, in order
#   phase_run <name> "<needs>" cmd...   run cmd unless a needed phase isn't "pass";
#                                       <needs> is phase names separated by "|"
#                                       (names may contain spaces), or ""
#   phase_report                        print the table (and the Actions job
#                                       summary); returns 1 unless all passed
# shellcheck disable=SC2034

declare -ga PHASE_ORDER=()
declare -gA PHASE_STATUS=() PHASE_NOTE=()

phase_expect() {
  local n
  for n in "$@"; do
    PHASE_ORDER+=("$n")
    PHASE_STATUS[$n]="not run"
    PHASE_NOTE[$n]=""
  done
}

phase_run() {
  local name="$1" needs="$2" dep rc
  shift 2
  local -a deps=()
  [ -z "$needs" ] || IFS='|' read -r -a deps <<<"$needs"
  for dep in "${deps[@]}"; do
    if [ "${PHASE_STATUS[$dep]:-not run}" != "pass" ]; then
      PHASE_STATUS[$name]="skipped"
      PHASE_NOTE[$name]="needs '$dep' (${PHASE_STATUS[$dep]:-not run})"
      printf '%s SKIP phase %s: %s\n' "$(date -u +%H:%M:%S)" "$name" "${PHASE_NOTE[$name]}" >&2
      return 0
    fi
  done
  printf '%s phase %s: start\n' "$(date -u +%H:%M:%S)" "$name" >&2
  if "$@"; then rc=0; else rc=$?; fi
  if [ "$rc" -eq 0 ]; then
    PHASE_STATUS[$name]="pass"
  else
    PHASE_STATUS[$name]="fail"
    PHASE_NOTE[$name]="exit $rc"
  fi
  printf '%s phase %s: %s\n' "$(date -u +%H:%M:%S)" "$name" "${PHASE_STATUS[$name]}" >&2
  return 0
}

phase_report() {
  local n bad=0 line
  {
    echo "Render e2e phases (${E2E_BRANCH:-?}); green only if every phase passes:"
    for n in "${PHASE_ORDER[@]}"; do
      line="  ${PHASE_STATUS[$n]}: $n"
      [ -z "${PHASE_NOTE[$n]}" ] || line+=" (${PHASE_NOTE[$n]})"
      echo "$line"
      [ "${PHASE_STATUS[$n]}" = "pass" ] || bad=1
    done
  } >&2
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### Render e2e phases (\`${E2E_BRANCH:-?}\`)"
      echo
      echo "| phase | outcome | note |"
      echo "|---|---|---|"
      for n in "${PHASE_ORDER[@]}"; do
        echo "| $n | ${PHASE_STATUS[$n]} | ${PHASE_NOTE[$n]} |"
      done
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  return "$bad"
}
