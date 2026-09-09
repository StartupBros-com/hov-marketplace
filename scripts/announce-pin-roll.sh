#!/usr/bin/env bash
set -euo pipefail

# announce-pin-roll.sh — move every catalog plugin's announce pin to a new helper sha.
#
# The companion to announce-pin-drift.sh: that one answers "is the fleet current", this one
# makes it so. Drift is reported by CI; rolling is deliberate and runs on an operator's or
# an agent's own credentials, so there is no workflow for it and no standing token anywhere.
#
# WHAT IT ENCODES
#
# Rolling this by hand on 2026-09-09 took two passes, because the change is not "sed the
# sha". Four things bite, and each is a case in tests/announce-pin-roll.test.sh:
#
#   1. Two shas move, not one. The hardened slot takes the new pin AND the retired slot
#      takes the pin just superseded, so the mutant that slot seeds still means "reverting
#      to the previous pin is rejected". Done naively -- replace(prev,old) then
#      replace(old,new) -- the second pass promotes the value the first just retired and
#      both slots collapse onto the new sha. Staged behind a sentinel instead.
#   2. The `uses:` line carries a trailing comment describing what that pin CHANGED. Move
#      the sha and leave the comment, and it advertises the superseded commit's fix against
#      the new sha: a comment asserting something the pinned code is not.
#   3. That comment cannot be anchored to the sha. Several repos assert the workflow file
#      BYTE-FOR-BYTE and build the `uses:` line by interpolation (Python f-string, JS
#      template literal), so the text reads `@{HARDENED_SHA} # fix: ...`; an anchor of
#      "<literal-sha> # fix: ..." matches nothing and leaves the note stale. Those
#      byte-for-byte assertions then fail in CI rather than locally.
#   4. It is not always release-train.yml. papercut also pins the announce workflow from
#      ci.yml, so every tracked file that mentions either sha is scanned.
#
# Modes, least to most:
#   (default)  dry run: report every file that would change, write nothing
#   --apply    rewrite the files in the local clones, stop before git
#   --ship     rewrite, commit, push and open a PR in each repo
#
# Exit codes:
#   0  nothing to do, or the requested work completed
#   1  a read, parse or write failure — NEVER interpreted as "nothing to do"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'USAGE'
usage: announce-pin-roll.sh --old <sha> --new <sha> [--prev <sha>]
                            [--old-note TEXT --new-note TEXT]
                            [--apply | --ship] [--only PLUGIN] [--root DIR]

  --old   the pin consumers currently carry (becomes the retired slot)
  --new   the pin they should carry
  --prev  the sha currently sitting in the retired slot, if any
  --old-note / --new-note  trailing comment on the `uses:` line, if the repos carry one
USAGE
  exit 2
}

# Rewrite one file's pin references, in place. Pure with respect to everything but this
# file, so the tests drive it directly against fixtures. Prints the path when it changed.
rewrite_pin_file() { # <file> <prev> <old> <new> <old-note> <new-note>
  python3 - "$@" <<'PY'
import sys
from pathlib import Path

path, prev, old, new, old_note, new_note = sys.argv[1:7]
p = Path(path)
s = p.read_text(encoding="utf-8")

# Already rolled? Stop. Both the rolled and unrolled states contain `old` -- unrolled as
# the hardened pin, rolled as the retired one -- so presence of `old` cannot tell them
# apart, and running again would rewrite the RETIRED slot to `new` and collapse both onto
# it. `new` is a fresh sha nothing references until the roll, so it is the discriminator.
# This matters because a roll across nine repositories is interruptible.
if new in s:
    raise SystemExit(0)

# The retirement is staged behind a sentinel: replacing prev->old and then old->new in
# sequence would promote the value just retired, collapsing both slots onto the new sha.
SENTINEL = "\x00RETIRED\x00"
out = s
if prev:
    out = out.replace(prev, SENTINEL)
out = out.replace(old, new)
if prev:
    out = out.replace(SENTINEL, old)

# The comment is replaced on its own, never anchored to the sha: files that build the
# `uses:` line by interpolation hold `@{HARDENED_SHA} # <note>`, where a sha-anchored
# pattern matches nothing and leaves the note describing the superseded commit.
if old_note and new_note:
    out = out.replace(old_note, new_note)

if out != s:
    p.write_text(out, encoding="utf-8")
    print(path)
PY
}

# owner/repo from a canonical card source url, refused rather than guessed — the same rule
# as repin-reconcile and announce-pin-drift.
repo_from_url() {
  local url="$1" path
  case "$url" in https://github.com/*) path="${url#https://github.com/}" ;; *) return 1 ;; esac
  path="${path%.git}"
  case "$path" in */*/*|'') return 1 ;; */*) printf '%s\n' "$path" ;; *) return 1 ;; esac
}

ship_one() { # <dir> <owner/repo> <branch> <new-sha>
  local dir="$1" repo="$2" branch="$3" new="$4"
  git -C "$dir" add -u
  git -C "$dir" commit -q -m "ci(release-train): pin the announce workflow to $new

The reusable workflow checks its helper out at ref: \${{ job.workflow_sha }}, so a fix on
hov-marketplace main is inert here until this pin moves." || return 1
  git -C "$dir" push -q origin "HEAD:refs/heads/$branch" || return 1
  gh pr create --repo "$repo" --head "$branch" --base main \
    --title "ci(release-train): pin the announce workflow to $new" \
    --body "Rolled by \`scripts/announce-pin-roll.sh\` in hov-marketplace. The reusable announce workflow checks its helper out at \`ref: \${{ job.workflow_sha }}\`, so a fix on marketplace main is inert in this repository until this pin moves." \
    >/dev/null 2>&1 || return 1
}

main() {
  local MANIFEST="${MANIFEST:-.claude-plugin/marketplace.json}"
  local ROOT="${ROOT:-$HOME/SITES}"
  local BRANCH="${BRANCH:-bump-announce-pin}"
  local MODE=report ONLY="" PREV_SHA="" OLD_SHA="" NEW_SHA="" OLD_NOTE="" NEW_NOTE=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --old) OLD_SHA="${2:-}"; shift 2 ;;
      --new) NEW_SHA="${2:-}"; shift 2 ;;
      --prev) PREV_SHA="${2:-}"; shift 2 ;;
      --old-note) OLD_NOTE="${2:-}"; shift 2 ;;
      --new-note) NEW_NOTE="${2:-}"; shift 2 ;;
      --only) ONLY="${2:-}"; shift 2 ;;
      --root) ROOT="${2:-}"; shift 2 ;;
      --apply) MODE=apply; shift ;;
      --ship) MODE=ship; shift ;;
      -h|--help) usage ;;
      *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
    esac
  done

  [ -n "$OLD_SHA" ] && [ -n "$NEW_SHA" ] || usage
  case "$OLD_SHA$NEW_SHA$PREV_SHA" in *[!0-9a-f]*) fail "shas must be lowercase hex" ;; esac
  [ "$OLD_SHA" != "$NEW_SHA" ] || fail "--old and --new are the same sha"
  [ -s "$MANIFEST" ] || fail "manifest not found: $MANIFEST"

  local touched=0 skipped=0 url repo name dir files changed rel c
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    repo="$(repo_from_url "$url")" || fail "unresolvable source url: $url"
    name="${repo##*/}"
    [ -z "$ONLY" ] || [ "$ONLY" = "$name" ] || continue

    dir="$ROOT/$name"
    if [ ! -d "$dir/.git" ]; then
      printf '%-16s SKIP no clone at %s\n' "$name" "$dir"
      skipped=$((skipped + 1)); continue
    fi

    # A local checkout is not current-state truth. These clones are launch pads and drift
    # behind origin/main routinely -- pro-gate's sat 8 commits back the day this was
    # written, still showing the superseded pin. Editing that working tree would diff
    # against stale content and quietly reintroduce it. Refuse instead of guessing: the
    # drift check already says what needs rolling, so a skipped repo is visible, not lost.
    git -C "$dir" fetch origin --quiet 2>/dev/null || true
    if ! git -C "$dir" merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
      printf '%-16s SKIP checkout does not contain origin/main; refusing to edit stale content\n' "$name"
      skipped=$((skipped + 1)); continue
    fi

    # Only files that already mention one of the shas are considered; nothing else is read
    # or written.
    if [ -n "$PREV_SHA" ]; then
      files="$(git -C "$dir" grep -l -e "$OLD_SHA" -e "$PREV_SHA" -- . 2>/dev/null || true)"
    else
      files="$(git -C "$dir" grep -l -e "$OLD_SHA" -- . 2>/dev/null || true)"
    fi
    # A rolled repository still mentions `old` -- in its RETIRED slot -- so the grep above
    # cannot tell rolled from unrolled on its own. Drop anything already carrying `new`,
    # the same discriminator rewrite_pin_file uses, so report mode does not claim work
    # that apply mode would then correctly decline to do.
    if [ -n "$files" ]; then
      files="$(printf '%s\n' "$files" | while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        grep -qF "$NEW_SHA" "$dir/$rel" 2>/dev/null || printf '%s\n' "$rel"
      done)"
    fi
    if [ -z "$files" ]; then
      printf '%-16s ok   already rolled, or does not pin the announce workflow\n' "$name"
      continue
    fi

    if [ "$MODE" = report ]; then
      printf '%-16s would rewrite: %s\n' "$name" "$(printf '%s' "$files" | tr '\n' ' ')"
      touched=$((touched + 1)); continue
    fi

    changed=""
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      c="$(rewrite_pin_file "$dir/$rel" "$PREV_SHA" "$OLD_SHA" "$NEW_SHA" "$OLD_NOTE" "$NEW_NOTE")"
      [ -z "$c" ] || changed="$changed $rel"
    done <<<"$files"

    if [ -z "$changed" ]; then
      printf '%-16s ok   no change after rewrite\n' "$name"; continue
    fi
    printf '%-16s rewrote:%s\n' "$name" "$changed"
    touched=$((touched + 1))

    [ "$MODE" = ship ] || continue
    if ship_one "$dir" "$repo" "$BRANCH" "$NEW_SHA"; then
      printf '%-16s PR opened\n' "$name"
    else
      printf '%-16s SKIP could not commit, push or open a PR\n' "$name"
    fi
  done < <(jq -r '.plugins[]? | .source.url // empty' "$MANIFEST")

  printf '\n%s consumer(s) affected, %s skipped (no clone, or checkout not current)\n' "$touched" "$skipped"
  [ "$MODE" != report ] || printf 'dry run: nothing written. Re-run with --apply or --ship.\n'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
