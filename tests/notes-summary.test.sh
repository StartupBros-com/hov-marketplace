#!/usr/bin/env bash
# Tests for notes_summary(): which release-body shapes produce card bullets,
# and that the prose fallback warns instead of degrading silently.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$HERE")"
PASS=0
FAIL=0
export REPOSITORY="stub-plugin" RELEASE_TAG="v1.2.3"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/tool-drop-announce.sh"

report() {
  if [[ "$2" == 0 ]]; then
    echo "ok - $1"
    PASS=$((PASS + 1))
  else
    echo "not ok - $1"
    FAIL=$((FAIL + 1))
  fi
}

# 1. Highlights bullets win, capped at 3, prefixes stripped.
(
  RELEASE_NOTES=$'## Highlights\n\n- feat: first thing\n- second thing\n- third thing\n- fourth thing\n\n## Details\nprose here'
  export RELEASE_NOTES
  out="$(notes_summary 2>/dev/null)"
  [[ "$(printf '%s' "$out" | wc -l)" == 2 ]] || exit 1   # 3 lines, no trailing NL
  printf '%s' "$out" | grep -q '^first thing$' || exit 1
  printf '%s' "$out" | grep -q 'fourth thing' && exit 1
  printf '%s' "$out" | grep -q 'prose here' && exit 1
  exit 0
)
report "Highlights bullets: capped at 3, conventional-commit prefix stripped" $?

# 2. No Highlights -> prose fallback AND a CI warning on stderr.
(
  RELEASE_NOTES=$'Born from a live outage: the thing wedged mid-session.\n\nMore detail below.'
  export RELEASE_NOTES
  err_file="$(mktemp)"
  out="$(notes_summary 2>"$err_file")"
  printf '%s' "$out" | grep -q 'Born from a live outage' || exit 1
  grep -q '::warning title=No release highlights::' "$err_file" || exit 1
  grep -q 'stub-plugin v1.2.3' "$err_file" || exit 1
  exit 0
)
report "prose fallback emits a ::warning (planted negative: silent degrade)" $?

# 3. GitHub auto "What's Changed" bullets are used, author/url noise stripped.
(
  RELEASE_NOTES=$'## What\'s Changed\n* fix: a real fix by @someone in https://github.com/o/r/pull/1\n\n**Full Changelog**: https://example.invalid'
  export RELEASE_NOTES
  out="$(notes_summary 2>/dev/null)"
  [[ "$out" == "a real fix" ]] || exit 1
)
report "What's Changed bullets used with author/URL noise stripped" $?

# 4. Empty notes -> empty output, no crash.
(
  RELEASE_NOTES=""
  export RELEASE_NOTES
  out="$(notes_summary 2>/dev/null)" || exit 1
  [[ -z "$out" ]] || exit 1
)
report "empty release body yields empty summary" $?

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
