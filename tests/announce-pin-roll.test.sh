#!/usr/bin/env bash
set -uo pipefail

# Tests for scripts/announce-pin-roll.sh.
#
# Every case below is a mistake that actually shipped, was caught in CI rather than
# locally, or was found by an adversarial pass over the first draft of this script.
#
# The decomposition matters: rewrite_pin_file is a pure per-file rewrite with NO
# already-rolled guard of its own, because no whole-file discriminator is correct -- a
# finished file that keeps a retired slot holds both shas, and an unrolled one may mention
# the new sha for an unrelated reason. Deciding what to touch belongs to roll_candidates,
# which selects on the repository's actual pin, and that is where those cases are proven.

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
# The sourced script sets -e for its own run. Left on, the first bare call below that
# returned nonzero would abort this file mid-suite and lose every later result and the
# tally. Restore the runner's own flags.
set +e
set -uo pipefail

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

# --- the transformation ------------------------------------------------------

# 1. Both slots move exactly one step, and the naive alternative provably does not.
f="$(fixture "HARDENED_SHA='$OLD'
RETIRED_SHA='$PREV'
")"
rewrite_pin_file "$f" "$PREV" "$OLD" "$NEW" "$OLD_NOTE" "$NEW_NOTE" >/dev/null
got="$(cat "$f")"
naive="$(printf "HARDENED_SHA='%s'\nRETIRED_SHA='%s'\n" "$OLD" "$PREV" \
  | sed "s/$PREV/$OLD/g" | sed "s/$OLD/$NEW/g")"
if [ "$got" = "HARDENED_SHA='$NEW'
RETIRED_SHA='$OLD'" ]; then
  pass "hardened takes the new sha and retired takes the one it supersedes"
else
  die "hardened/retired each move one step, got: $got"
fi
if printf '%s' "$naive" | grep -q "RETIRED_SHA='$NEW'"; then
  pass "planted negative: the naive sequential replace does collapse both slots"
else
  die "planted negative did not reproduce the collapse it guards against"
fi

# 2. The trailing comment moves with the sha, or it advertises the superseded fix.
f="$(fixture "    uses: …/hov-tool-drop-announce.yml@$OLD $OLD_NOTE
")"
rewrite_pin_file "$f" "$PREV" "$OLD" "$NEW" "$OLD_NOTE" "$NEW_NOTE" >/dev/null
if grep -q "@$NEW $NEW_NOTE" "$f" && ! grep -qF "$OLD_NOTE" "$f"; then
  pass "the uses: comment is updated alongside the sha"
else
  die "the uses: comment is updated alongside the sha, got: $(cat "$f")"
fi

# 3. The comment cannot be anchored to the sha: these build the line by interpolation, and
#    all four such repos failed CI on the first hand roll for exactly this reason.
f="$(fixture "HARDENED_SHA = \"$OLD\"
EXPECTED = f\"    uses: …@{HARDENED_SHA} $OLD_NOTE\"
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

# 4. A consumer with no retired slot and no comment still rolls.
f="$(fixture "    uses: …/hov-tool-drop-announce.yml@$OLD
")"
rewrite_pin_file "$f" "" "$OLD" "$NEW" "" "" >/dev/null
if grep -q "@$NEW\$" "$f"; then
  pass "a workflow-only consumer rolls without a retired slot or a comment"
else
  die "a workflow-only consumer rolls, got: $(cat "$f")"
fi

# 5. A file mentioning neither sha is never rewritten.
f="$(fixture "nothing to see here
")"
before="$(cat "$f")"
out="$(rewrite_pin_file "$f" "$PREV" "$OLD" "$NEW" "$OLD_NOTE" "$NEW_NOTE")"
if [ -z "$out" ] && [ "$(cat "$f")" = "$before" ]; then
  pass "an unrelated file is untouched and silent"
else
  die "an unrelated file is untouched, out='$out'"
fi

# --- deciding what to touch --------------------------------------------------
#
# This is pin-driven, not file-driven: a correctly rolled file that keeps a retired slot
# holds BOTH shas, so file-level presence cannot tell a finished repository from one that
# still needs work. These build real repositories so the selection is exercised as shipped.

mkrepo() { # <name> <pin> [extra-file-content] -> dir
  local rname="$1" pin="$2" extra="${3:-}"
  local d="$TMP/repo-$rname"
  mkdir -p "$d/.github/workflows"
  printf 'jobs:\n  announce:\n    uses: StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@%s\n' \
    "$pin" > "$d/.github/workflows/release-train.yml"
  [ -z "$extra" ] || printf '%s' "$extra" > "$d/pins.txt"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" add -A >/dev/null 2>&1
  printf '%s\n' "$d"
}

# 6. A finished repository is selected for nothing, so a re-run over a partly-rolled fleet
#    cannot rewrite a retired slot back onto the new sha. The transform itself would
#    happily do that, which is exactly why the decision does not live there.
d="$(mkrepo rolled "$NEW" "HARDENED_SHA='$NEW'
RETIRED_SHA='$OLD'
")"
if [ -z "$(roll_candidates "$d" "$NEW" "$PREV" "$OLD" "$NEW")" ]; then
  pass "a rolled repository selects no files, even though its retired slot holds the old sha"
else
  die "a rolled repository selects no files, got: $(roll_candidates "$d" "$NEW" "$PREV" "$OLD" "$NEW")"
fi

# 7. The taint case an adversarial pass found: a pin still on old, in a file that also
#    mentions the new sha for an unrelated reason. Selecting on the PIN gets this right --
#    an earlier whole-file "contains new" discriminator skipped it and never rolled the pin.
d="$(mkrepo tainted "$OLD" "# changelog: superseded by commit $NEW
")"
if [ -n "$(roll_candidates "$d" "$OLD" "$PREV" "$OLD" "$NEW")" ]; then
  pass "an unrolled pin is selected even when the repo mentions the new sha elsewhere (planted negative)"
else
  die "an unrolled pin is selected despite an unrelated mention of the new sha"
fi

# 8. The interrupted roll: workflow already moved, a test constant left behind.
d="$(mkrepo partial "$NEW" "HARDENED_SHA='$OLD'
RETIRED_SHA='$PREV'
")"
if printf '%s' "$(roll_candidates "$d" "$NEW" "$PREV" "$OLD" "$NEW")" | grep -q 'pins.txt'; then
  pass "a partly-rolled repository still selects the file whose retired slot is unfinished"
else
  die "a partly-rolled repository selects its unfinished file"
fi

# 9. An ordinary unrolled repository selects its workflow.
d="$(mkrepo plain "$OLD")"
if printf '%s' "$(roll_candidates "$d" "$OLD" "$PREV" "$OLD" "$NEW")" | grep -q 'release-train.yml'; then
  pass "an unrolled repository selects its workflow"
else
  die "an unrolled repository selects its workflow"
fi

# --- input validation --------------------------------------------------------

# 9. An abbreviated sha passes a hex-only check and then corrupts any longer hex string
#    sharing its prefix, because the rewrite is a substring replace. Length is enforced.
if valid_sha "$OLD"; then
  pass "a full 40-character sha is accepted"
else
  die "a full 40-character sha is accepted"
fi
if valid_sha abc1234; then
  die "an abbreviated sha is refused"
else
  pass "an abbreviated sha is refused (it would corrupt any hex string sharing its prefix)"
fi
if valid_sha "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"; then
  die "a non-hex value is refused"
else
  pass "a non-hex value is refused"
fi

# 10. The driver refuses argument combinations that would silently do nothing or corrupt.
for bad in "--old $OLD --new $OLD" "--old abc1234 --new $NEW" "--new $NEW" \
           "--old $OLD --new $NEW --prev $OLD"; do
  # shellcheck disable=SC2086
  if ( main $bad ) >/dev/null 2>&1; then
    die "refused: $bad"
  else
    pass "refused: $bad"
  fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
