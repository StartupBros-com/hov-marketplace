#!/usr/bin/env bash
set -euo pipefail

# announce-pin-roll.sh — rewrite every catalog plugin's announce pin to a new helper sha.
#
# The companion to announce-pin-drift.sh: that one answers "is the fleet current", this one
# performs the edit. It edits files and stops. Committing, pushing and opening PRs stays
# with the caller, deliberately: an earlier draft did all three across nine repositories on
# a bare `git add -u`, which sweeps every locally-modified tracked file — a colleague's WIP
# included — into a commit titled "pin the announce workflow". The encoded knowledge here
# is the transformation, not the git.
#
# WHAT IT ENCODES
#
# Rolling this by hand on 2026-09-09 took two passes and produced four red PRs, because the
# change is not "sed the sha". Each trap below is a case in tests/announce-pin-roll.test.sh:
#
#   1. Two shas move, not one. The hardened slot takes the new pin AND the retired slot
#      takes the pin just superseded, so the mutant that slot seeds still means "reverting
#      to the previous pin is rejected". Done naively -- replace(prev,old) then
#      replace(old,new) -- the second pass promotes what the first just retired and both
#      slots collapse onto the new sha. Staged behind a sentinel instead.
#   2. The `uses:` line's trailing comment describes what that pin CHANGED, so it moves
#      with the sha or it advertises the superseded commit's fix against the new one.
#   3. That comment cannot be anchored to the sha. Several repos assert the workflow file
#      BYTE-FOR-BYTE and build the line by interpolation (`@{HARDENED_SHA} # fix: ...`),
#      where a "<literal-sha> # fix: ..." anchor matches nothing and the note stays stale.
#   4. It is not always release-train.yml -- papercut also pins from ci.yml.
#
# WHAT IT REFUSES
#
# Every ambiguity is a refusal, never a silent pass. A checkout whose freshness cannot be
# verified, a repository pinning two different shas, and a pin that is neither the old nor
# the new sha are all reported and counted; none is quietly folded into "already rolled".
# That last one matters most: a consumer more than one hop behind mentions neither sha, and
# an earlier draft printed "already rolled" for it — a clean summary for a repository the
# drift check still calls broken.
#
# Exit codes:
#   0  every consumer is rolled or already current
#   1  at least one consumer was refused, or a read/parse failure

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'USAGE'
usage: announce-pin-roll.sh --old <sha40> --new <sha40> [--prev <sha40>]
                            [--old-note TEXT --new-note TEXT]
                            [--apply] [--only PLUGIN] [--root DIR]

  --old   the pin consumers currently carry (becomes the retired slot)
  --new   the pin they should carry
  --prev  the sha currently sitting in the retired slot, if the repos keep one
  --old-note / --new-note  trailing comment on the `uses:` line, if they carry one
  --apply rewrite files; without it this is a dry run that writes nothing

Commit, push and open the PRs yourself; this only edits.
USAGE
  exit 2
}

# A pin must be a full 40-character sha. Abbreviations are refused rather than accepted:
# the rewrite is a plain substring replace, so a 7-character value would also match inside
# any longer hex string that shares its prefix -- a docker digest, an unrelated commit
# reference -- and corrupt it with no error.
valid_sha() { case "$1" in *[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -eq 40 ]; }

# Rewrite one file's pin references, in place. Pure with respect to everything but this
# file, so the tests drive it directly. Prints the path when it changed something.
rewrite_pin_file() { # <file> <prev> <old> <new> <old-note> <new-note>
  python3 - "$@" <<'PY'
import sys
from pathlib import Path

path, prev, old, new, old_note, new_note = sys.argv[1:7]
p = Path(path)
s = p.read_text(encoding="utf-8")

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

# Which files a roll must touch, given the sha the repository is actually pinned to.
#
# File-level presence cannot decide this. A correctly rolled file that keeps a retired slot
# holds BOTH shas -- new as hardened, old as retired -- so "contains old" and "contains
# new" are both true of a finished repository. The pin is what disambiguates:
#
#   pin == old  the repository is unrolled; everything mentioning old or prev is in scope
#   pin == new  the workflow is already rolled, so only a file still carrying `prev` has an
#               unfinished retired slot -- the interrupted-roll case
#
# This also disposes of the taint case: a workflow whose pin is still old but which happens
# to mention the new sha elsewhere is selected on its pin, and the unrelated mention is
# left exactly as it is.
roll_candidates() { # <dir> <pin> <prev> <old> <new>
  local dir="$1" pin="$2" prev="$3" old="$4" new="$5"
  if [ "$pin" = "$new" ]; then
    [ -n "$prev" ] || return 0
    git -C "$dir" grep -l -F -e "$prev" -- . 2>/dev/null || true
    return 0
  fi
  if [ -n "$prev" ]; then
    git -C "$dir" grep -l -F -e "$old" -e "$prev" -- . 2>/dev/null || true
  else
    git -C "$dir" grep -l -F -e "$old" -- . 2>/dev/null || true
  fi
}

# owner/repo from a canonical card source url, refused rather than guessed — the same rule
# as repin-reconcile and announce-pin-drift.
repo_from_url() {
  local url="$1" path
  case "$url" in https://github.com/*) path="${url#https://github.com/}" ;; *) return 1 ;; esac
  path="${path%.git}"
  case "$path" in */*/*|'') return 1 ;; */*) printf '%s\n' "$path" ;; *) return 1 ;; esac
}

# Every announce pin a checkout carries, deduplicated. Scans the whole workflows directory
# rather than assuming release-train.yml, and is what lets this agree with the drift check
# about which sha a repository is actually on.
checkout_pins() { # <dir>
  local dir="$1"
  [ -d "$dir/.github/workflows" ] || return 0
  grep -rhoE 'hov-tool-drop-announce\.yml@[0-9a-f]{40}' "$dir/.github/workflows" 2>/dev/null \
    | sed 's/.*@//' | sort -u
}

main() {
  local MANIFEST="${MANIFEST:-.claude-plugin/marketplace.json}"
  local ROOT="${ROOT:-$HOME/SITES}"
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
      -h|--help) usage ;;
      *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
    esac
  done

  [ -n "$OLD_SHA" ] && [ -n "$NEW_SHA" ] || usage
  valid_sha "$OLD_SHA" || fail "--old must be 40 lowercase hex characters"
  valid_sha "$NEW_SHA" || fail "--new must be 40 lowercase hex characters"
  [ -z "$PREV_SHA" ] || valid_sha "$PREV_SHA" || fail "--prev must be 40 lowercase hex characters"
  [ "$OLD_SHA" != "$NEW_SHA" ] || fail "--old and --new are the same sha"
  # prev == old makes the sentinel dance a round trip -- every `old` is masked as retired,
  # nothing is left for old->new, and the mask is restored: a silent whole-file no-op.
  [ -z "$PREV_SHA" ] || [ "$PREV_SHA" != "$OLD_SHA" ] || fail "--prev and --old are the same sha"
  [ -z "$PREV_SHA" ] || [ "$PREV_SHA" != "$NEW_SHA" ] || fail "--prev and --new are the same sha"
  [ -s "$MANIFEST" ] || fail "manifest not found: $MANIFEST"

  local rolled=0 current=0 refused=0
  local url repo name dir pins pin_count pin rel changed c candidates
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    repo="$(repo_from_url "$url")" || fail "unresolvable source url: $url"
    name="${repo##*/}"
    [ -z "$ONLY" ] || [ "$ONLY" = "$name" ] || continue

    dir="$ROOT/$name"
    if [ ! -d "$dir/.git" ]; then
      printf '%-16s REFUSED  no clone at %s\n' "$name" "$dir"
      refused=$((refused + 1)); continue
    fi

    # A local checkout is not current-state truth -- these are launch pads and drift behind
    # origin/main routinely. Editing a stale working tree diffs against outdated content
    # and quietly reintroduces it. The fetch's own exit status is checked: swallowing it
    # would leave origin/main pointing at whatever was fetched last, and the ancestry test
    # below would then pass against stale data, which is a guard that cannot fail.
    if ! git -C "$dir" fetch origin --quiet 2>/dev/null; then
      printf '%-16s REFUSED  could not fetch; freshness unverifiable\n' "$name"
      refused=$((refused + 1)); continue
    fi
    if ! git -C "$dir" merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
      printf '%-16s REFUSED  checkout does not contain origin/main\n' "$name"
      refused=$((refused + 1)); continue
    fi

    # Classify by the pin the checkout actually carries, so this and the drift check never
    # disagree about a repository's state.
    pins="$(checkout_pins "$dir")"
    pin_count="$(printf '%s' "$pins" | grep -c . || true)"
    if [ "$pin_count" -eq 0 ]; then
      printf '%-16s ok       does not pin the announce workflow\n' "$name"; continue
    fi
    if [ "$pin_count" -gt 1 ]; then
      printf '%-16s REFUSED  pins %s different shas: %s\n' "$name" "$pin_count" "$(printf '%s' "$pins" | tr '\n' ' ')"
      refused=$((refused + 1)); continue
    fi
    pin="$pins"
    if [ "$pin" != "$OLD_SHA" ] && [ "$pin" != "$NEW_SHA" ]; then
      printf '%-16s REFUSED  pinned to %s, which is neither --old nor --new\n' "$name" "${pin:0:7}"
      refused=$((refused + 1)); continue
    fi

    candidates="$(roll_candidates "$dir" "$pin" "$PREV_SHA" "$OLD_SHA" "$NEW_SHA")"
    if [ -z "$candidates" ]; then
      if [ "$pin" = "$NEW_SHA" ]; then
        printf '%-16s ok       already rolled\n' "$name"; current=$((current + 1))
      else
        printf '%-16s ok       nothing to rewrite\n' "$name"
      fi
      continue
    fi

    if [ "$MODE" = report ]; then
      printf '%-16s would rewrite: %s\n' "$name" "$(printf '%s' "$candidates" | tr '\n' ' ')"
      rolled=$((rolled + 1)); continue
    fi

    changed=""
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      c="$(rewrite_pin_file "$dir/$rel" "$PREV_SHA" "$OLD_SHA" "$NEW_SHA" "$OLD_NOTE" "$NEW_NOTE")"
      [ -z "$c" ] || changed="$changed $rel"
    done <<<"$candidates"

    if [ -z "$changed" ]; then
      printf '%-16s ok       no change after rewrite\n' "$name"; continue
    fi
    printf '%-16s rewrote:%s\n' "$name" "$changed"
    rolled=$((rolled + 1))
  done < <(jq -r '.plugins[]? | .source.url // empty' "$MANIFEST")

  printf '\n%s to roll or rolled, %s already current, %s refused\n' "$rolled" "$current" "$refused"
  if [ "$MODE" = report ]; then
    printf 'dry run: nothing written. Re-run with --apply, then commit and open the PRs yourself.\n'
  fi
  [ "$refused" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
