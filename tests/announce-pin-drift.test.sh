#!/usr/bin/env bash
set -uo pipefail

# Tests for scripts/announce-pin-drift.sh.
#
# The check's only job is to answer "is the fleet running main's helper bytes", so the
# properties worth proving are the ones that would make a green answer a lie: that it
# actually detects a stale consumer, that a consumer it could not READ is never reported
# as current, and that it does not cry drift for a consumer pinning an older commit whose
# helper bytes are identical -- the noise that would get it switched off.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/announce-pin-drift.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
die() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

MAIN_BLOB=1111111111111111111111111111111111111111
OLD_BLOB=2222222222222222222222222222222222222222
PIN_CURRENT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PIN_SAMEBYTES=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
PIN_STALE=cccccccccccccccccccccccccccccccccccccccc

mkdir -p "$TMP/bin"

# Stub gh. It honours --jq because the script relies on gh applying that filter; a stub
# that ignored it would hand back raw JSON and exercise a shape production never sees.
# Fixture layout under $FIX:
#   blob/<ref>                 -> the helper blob id at that ref ("" or missing = unreadable)
#   repo/<name>/branch         -> that consumer's default branch (missing = unreadable repo)
#   repo/<name>/wf/<file>      -> that consumer's workflow file contents
cat > "$TMP/bin/gh" <<'STUBGH'
#!/usr/bin/env bash
set -uo pipefail
path="$2"; shift 2
jqexpr=""
while [ $# -gt 0 ]; do
  case "$1" in --jq) jqexpr="$2"; shift 2 ;; *) shift ;; esac
done
emit() { if [ -n "$jqexpr" ]; then jq -r "$jqexpr"; else cat; fi; }

ref="${path#*\?ref=}"; [ "$ref" = "$path" ] && ref=""
bare="${path%%\?*}"

case "$bare" in
  repos/StartupBros-com/hov-marketplace/contents/scripts/tool-drop-announce.sh)
    b="$(cat "$FIX/blob/$ref" 2>/dev/null || true)"
    [ -n "$b" ] || exit 1
    printf '{"sha":"%s"}\n' "$b" | emit ;;
  repos/StartupBros-com/hov-marketplace)
    printf '{"default_branch":"main"}\n' | emit ;;
  repos/*/contents/.github/workflows)
    name="${bare#repos/StartupBros-com/}"; name="${name%%/*}"
    d="$FIX/repo/$name/wf"
    [ -d "$d" ] || exit 1
    { printf '['; first=1
      for f in "$d"/*; do
        [ -e "$f" ] || continue
        [ "$first" = 1 ] || printf ','
        printf '{"type":"file","name":"%s"}' "$(basename "$f")"; first=0
      done
      printf ']\n'; } | emit ;;
  repos/*/contents/.github/workflows/*)
    name="${bare#repos/StartupBros-com/}"; name="${name%%/*}"
    file="${bare##*/}"
    f="$FIX/repo/$name/wf/$file"
    [ -f "$f" ] || exit 1
    printf '{"content":"%s"}\n' "$(base64 -w0 <"$f")" | emit ;;
  repos/*)
    name="${bare#repos/StartupBros-com/}"
    b="$(cat "$FIX/repo/$name/branch" 2>/dev/null || true)"
    [ -n "$b" ] || exit 1
    printf '{"default_branch":"%s"}\n' "$b" | emit ;;
  *) printf 'unexpected gh api: %s\n' "$path" >&2; exit 1 ;;
esac
STUBGH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

reset_fixture() {
  export FIX="$TMP/fix"
  rm -rf "$FIX"; mkdir -p "$FIX/blob" "$FIX/repo"
  printf '%s' "$MAIN_BLOB"     > "$FIX/blob/main"
  printf '%s' "$MAIN_BLOB"     > "$FIX/blob/$PIN_CURRENT"
  # A DIFFERENT commit whose helper bytes are identical: must not read as drift.
  printf '%s' "$MAIN_BLOB"     > "$FIX/blob/$PIN_SAMEBYTES"
  printf '%s' "$OLD_BLOB"      > "$FIX/blob/$PIN_STALE"
}

add_consumer() { # <name> <pin|NONE> [second-pin]
  local name="$1" pin="$2" second="${3:-}"
  mkdir -p "$FIX/repo/$name/wf"
  printf 'main' > "$FIX/repo/$name/branch"
  if [ "$pin" = NONE ]; then
    printf 'jobs:\n  build:\n    runs-on: ubuntu-24.04\n' > "$FIX/repo/$name/wf/ci.yml"
    return
  fi
  printf 'jobs:\n  announce:\n    uses: StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@%s\n' \
    "$pin" > "$FIX/repo/$name/wf/release-train.yml"
  [ -z "$second" ] || printf 'jobs:\n  other:\n    uses: StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@%s\n' \
    "$second" > "$FIX/repo/$name/wf/ci.yml"
}

write_manifest() { # <name>...
  { printf '{"plugins":['; local first=1
    for n in "$@"; do
      [ "$first" = 1 ] || printf ','
      printf '{"name":"%s","source":{"url":"https://github.com/StartupBros-com/%s.git"}}' "$n" "$n"
      first=0
    done
    printf ']}\n'; } > "$FIX/manifest.json"
}

run_check() { MANIFEST="$FIX/manifest.json" bash "$SCRIPT" 2>&1; }

# 1. every consumer on main's bytes
reset_fixture; add_consumer alpha "$PIN_CURRENT"; add_consumer beta "$PIN_CURRENT"
write_manifest alpha beta
out="$(run_check)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'fleet current'; then
  pass "a fleet on main's helper bytes exits 0"
else
  die "a fleet on main's helper bytes exits 0 (rc=$rc): $out"
fi

# 2. the planted negative: one stale consumer must be caught and named
reset_fixture; add_consumer alpha "$PIN_CURRENT"; add_consumer beta "$PIN_STALE"
write_manifest alpha beta
out="$(run_check)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'beta.*DRIFTED'; then
  pass "a consumer running a different helper is reported as drifted (planted negative)"
else
  die "a consumer running a different helper is reported as drifted (rc=$rc): $out"
fi

# 3. the property the whole design rests on: an OLDER pin with identical bytes is current.
#    Without this the check fires on every unrelated commit and gets switched off.
reset_fixture; add_consumer alpha "$PIN_SAMEBYTES"
write_manifest alpha
out="$(run_check)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'alpha.*current'; then
  pass "an older pin whose helper bytes match is current, not drift"
else
  die "an older pin whose helper bytes match is current, not drift (rc=$rc): $out"
fi

# 4. fail closed: a consumer we cannot read is never reported current
reset_fixture; add_consumer alpha "$PIN_CURRENT"
write_manifest alpha ghost   # ghost has no fixture at all
out="$(run_check)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'ghost.*UNREADABLE'; then
  pass "a consumer that cannot be read is UNREADABLE, never current"
else
  die "a consumer that cannot be read is UNREADABLE, never current (rc=$rc): $out"
fi

# 5. a pin this repo cannot resolve is a problem, not a match
reset_fixture; add_consumer alpha dddddddddddddddddddddddddddddddddddddddd
write_manifest alpha
out="$(run_check)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'alpha.*UNREADABLE'; then
  pass "a pin that does not resolve in this repo is refused, not treated as current"
else
  die "a pin that does not resolve in this repo is refused (rc=$rc): $out"
fi

# 6. two different pins in one consumer is ambiguous, not silently first-wins
reset_fixture; add_consumer alpha "$PIN_CURRENT" "$PIN_STALE"
write_manifest alpha
out="$(run_check)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'alpha.*AMBIGUOUS'; then
  pass "a consumer pinning two different shas is ambiguous"
else
  die "a consumer pinning two different shas is ambiguous (rc=$rc): $out"
fi

# 7. a plugin that never calls the shared workflow is not a failure
reset_fixture; add_consumer alpha "$PIN_CURRENT"; add_consumer solo NONE
write_manifest alpha solo
out="$(run_check)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'solo.*no announce pin'; then
  pass "a plugin that does not call the shared workflow is not counted as drift"
else
  die "a plugin that does not call the shared workflow is not counted as drift (rc=$rc): $out"
fi

# 8. a card whose source url is not a github https url is refused rather than skipped
reset_fixture; add_consumer alpha "$PIN_CURRENT"
printf '{"plugins":[{"name":"alpha","source":{"url":"https://github.com/StartupBros-com/alpha.git"}},{"name":"weird","source":{"url":"git@github.com:StartupBros-com/weird.git"}}]}\n' \
  > "$FIX/manifest.json"
out="$(run_check)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'unresolvable source url'; then
  pass "a card with a non-https source url is refused, not skipped"
else
  die "a card with a non-https source url is refused, not skipped (rc=$rc): $out"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
