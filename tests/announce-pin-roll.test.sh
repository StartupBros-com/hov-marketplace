#!/usr/bin/env bash
set -uo pipefail

# Tests for scripts/announce-pin-roll.sh.
#
# The driver is thin; the transformation is where rolling this by hand went wrong twice on
# 2026-09-09, so that is what is exercised here. Every case below is a mistake that
# actually shipped or was caught in CI rather than locally.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
die() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# Sourcing must not run the driver, or every test would trip the usage guard.
# shellcheck source=/dev/null
source "$ROOT/scripts/announce-pin-roll.sh"

PREV=cccccccccccccccccccccccccccccccccccccccc
OLD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NEW=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
OLD_NOTE='# fix: bind Tool Drop intent to the promoted release'
NEW_NOTE='# fix: retry the promotion-propagation 403'

n=0
fixture() { # <content> -> path
  n=$((n + 1))
  printf '%s' "$1" > "$TMP/f$n"
  printf '%s\n' "$TMP/f$n"
}

# 1. Both slots move exactly one step. The planted negative is the naive
#    replace(prev,old);replace(old,new) sequence, which promotes what it just retired.
f="$(fixture "HARDENED_SHA='$OLD'
RETIRED_SHA='$PREV'
")"
rewrite_pin_file "$f" "$PREV" "$OLD" "$NEW" "$OLD_NOTE" "$NEW_NOTE" >/dev/null
got="$(cat "$f")"
naive="$(printf 'HARDENED_SHA=%s\nRETIRED_SHA=%s\n' "'$OLD'" "'$PREV'" \
  | sed "s/$PREV/$OLD/g" | sed "s/$OLD/$NEW/g")"
if [ "$got" = "HARDENED_SHA='$NEW'
RETIRED_SHA='$OLD'" ]; then
  pass "hardened takes the new sha and retired takes the one it supersedes"
else
  die "hardened/retired each move one step, got: $got"
fi
if printf '%s' "$naive" | grep -q "RETIRED_SHA='$NEW'"; then
  pass "planted negative: the naive sequential replace does collapse both slots onto the new sha"
else
  die "planted negative did not reproduce the collapse it is guarding against"
fi

# 2. The trailing comment on the `uses:` line describes what the pin changed, so it moves
#    with the sha or it starts advertising the superseded commit's fix.
f="$(fixture "    uses: StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@$OLD $OLD_NOTE
")"
rewrite_pin_file "$f" "$PREV" "$OLD" "$NEW" "$OLD_NOTE" "$NEW_NOTE" >/dev/null
if grep -q "@$NEW $NEW_NOTE" "$f" && ! grep -qF "$OLD_NOTE" "$f"; then
  pass "the uses: comment is updated alongside the sha"
else
  die "the uses: comment is updated alongside the sha, got: $(cat "$f")"
fi

# 3. The comment cannot be anchored to the sha. These files build the line by
#    interpolation, so a "<sha> # note" anchor matches nothing — this is exactly what got
#    through locally and failed CI in design-rails, memory-dream, skill-tuner and wsl-cdp.
f="$(fixture "HARDENED_SHA = \"$OLD\"
EXPECTED = f\"\"\"
    uses: StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@{HARDENED_SHA} $OLD_NOTE
\"\"\"
")"
rewrite_pin_file "$f" "$PREV" "$OLD" "$NEW" "$OLD_NOTE" "$NEW_NOTE" >/dev/null
if grep -qF "$NEW_NOTE" "$f" && ! grep -qF "$OLD_NOTE" "$f"; then
  pass "an interpolated uses: line still gets its comment updated (f-string)"
else
  die "an interpolated uses: line still gets its comment updated, got: $(cat "$f")"
fi

f="$(fixture "const hardenedSha = \"$OLD\";
const retiredSha = \"$PREV\";
const expected = \`    uses: …@\${hardenedSha} $OLD_NOTE\`;
")"
rewrite_pin_file "$f" "$PREV" "$OLD" "$NEW" "$OLD_NOTE" "$NEW_NOTE" >/dev/null
if grep -qF "$NEW_NOTE" "$f" && grep -q "retiredSha = \"$OLD\"" "$f"; then
  pass "a template-literal fixture updates both its comment and its retired slot"
else
  die "a template-literal fixture updates comment and retired slot, got: $(cat "$f")"
fi

# 4. A repo with no retired slot and no comment still rolls.
f="$(fixture "    uses: StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@$OLD
")"
rewrite_pin_file "$f" "" "$OLD" "$NEW" "" "" >/dev/null
if grep -q "@$NEW\$" "$f"; then
  pass "a workflow-only consumer rolls without a retired slot or a comment"
else
  die "a workflow-only consumer rolls, got: $(cat "$f")"
fi

# 5. Idempotence: rolling an already-rolled file changes nothing and reports nothing, so a
#    re-run over a partly-rolled fleet cannot double-shift the retired slot.
f="$(fixture "HARDENED_SHA='$NEW'
RETIRED_SHA='$OLD'
")"
before="$(cat "$f")"
out="$(rewrite_pin_file "$f" "$PREV" "$OLD" "$NEW" "$OLD_NOTE" "$NEW_NOTE")"
if [ -z "$out" ] && [ "$(cat "$f")" = "$before" ]; then
  pass "an already-rolled file is left alone and reports no change"
else
  die "an already-rolled file is left alone, out='$out' content='$(cat "$f")'"
fi

# 6. A file mentioning neither sha is never rewritten.
f="$(fixture "nothing to see here
")"
before="$(cat "$f")"
out="$(rewrite_pin_file "$f" "$PREV" "$OLD" "$NEW" "$OLD_NOTE" "$NEW_NOTE")"
if [ -z "$out" ] && [ "$(cat "$f")" = "$before" ]; then
  pass "an unrelated file is untouched and silent"
else
  die "an unrelated file is untouched, out='$out'"
fi

# 7. The driver refuses input that would corrupt a pin rather than guessing.
if ( main --old "$OLD" --new "$OLD" ) >/dev/null 2>&1; then
  die "identical --old and --new is refused"
else
  pass "identical --old and --new is refused"
fi
if ( main --old "zzzz" --new "$NEW" ) >/dev/null 2>&1; then
  die "a non-hex sha is refused"
else
  pass "a non-hex sha is refused"
fi
if ( main --new "$NEW" ) >/dev/null 2>&1; then
  die "a missing --old is refused"
else
  pass "a missing --old is refused"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
