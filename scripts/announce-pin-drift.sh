#!/usr/bin/env bash
set -euo pipefail

# announce-pin-drift.sh — report catalog plugins running a stale announce helper.
#
# WHY THIS EXISTS
#
# The reusable announce workflow checks its helper out at `ref: ${{ job.workflow_sha }}`,
# so the code that actually runs is whatever the CALLER pinned — not this repo's main.
# Fixing scripts/tool-drop-announce.sh therefore ships nothing until every consumer bumps
# its `uses: ...@<sha>`. That gap is silent in both directions: nothing here reports the
# stale consumers, and a consumer's release train stays green while running old code.
#
# It has already bitten: every one of the nine plugins pinned 08f7d22 (2026-08-11) while
# main had gained 442ddff (2026-08-21) — "report a skipped announce loudly instead of
# silently going green". A fix about silent failure, silently not shipped, for 19 days.
#
# WHAT IT COMPARES, AND WHY IT IS CONTENT NOT SHA
#
# A consumer pinning an older commit is perfectly fine as long as the helper BYTES match.
# Between 2026-08-08 and 2026-09-09 this repo took 111 commits, of which 12 touched the
# helper: a SHA comparison would have cried drift 111 times, nine tenths of it noise, and
# been switched off inside a week. So this compares the helper's git BLOB at the pinned ref
# against the blob on the default branch. The contents API returns that blob id directly,
# so no file bytes are downloaded to make the comparison.
#
# WHAT IT DELIBERATELY DOES NOT DO
#
# No writes anywhere — not here, not in the consumers. No PRs, no issues, no new
# credential: every consumer is public, so the workflow's own GITHUB_TOKEN is enough. It
# reports one fact, is the fleet current, and leaves the acting to a human or an agent.
#
# Exit codes:
#   0  every consumer runs the default branch's helper bytes
#   1  at least one consumer is stale, ambiguous, or could not be checked
#
# A consumer that cannot be READ is never reported as current. A check that cannot make
# its comparison has to refuse, or it quietly becomes a green light for unknown state.

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

MANIFEST="${MANIFEST:-.claude-plugin/marketplace.json}"
SELF_REPO="${SELF_REPO:-StartupBros-com/hov-marketplace}"
HELPER_PATH="${HELPER_PATH:-scripts/tool-drop-announce.sh}"
ANNOUNCE_WORKFLOW="${ANNOUNCE_WORKFLOW:-hov-tool-drop-announce.yml}"

[ -s "$MANIFEST" ] || fail "manifest not found: $MANIFEST"

# owner/repo from a canonical card source url. Anything that is not a github.com https
# url is refused rather than guessed, matching repin-reconcile: a card we cannot resolve
# is a card we must not silently skip.
repo_from_url() {
  local url="$1" path
  case "$url" in
    https://github.com/*) path="${url#https://github.com/}" ;;
    *) return 1 ;;
  esac
  path="${path%.git}"
  case "$path" in
    */*/*|'') return 1 ;;
    */*) printf '%s\n' "$path" ;;
    *) return 1 ;;
  esac
}

# The helper's blob id at a ref. Empty output means "could not determine", which every
# caller treats as a problem rather than as a match.
helper_blob_at() { # <ref>
  gh api "repos/$SELF_REPO/contents/$HELPER_PATH?ref=$1" --jq '.sha' 2>/dev/null || true
}

# Every announce pin a consumer carries, deduplicated. Scans the whole workflows
# directory rather than assuming release-train.yml: papercut also pins the announce
# workflow from ci.yml, and a repo that pins two DIFFERENT shas is itself a finding.
consumer_pins() { # <owner/repo> <default-branch>
  local repo="$1" branch="$2" name body
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    body="$(gh api "repos/$repo/contents/.github/workflows/$name?ref=$branch" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)"
    [ -n "$body" ] || continue
    printf '%s\n' "$body" | grep -oE "$ANNOUNCE_WORKFLOW@[0-9a-f]{40}" | sed "s/^$ANNOUNCE_WORKFLOW@//" || true
  done < <(gh api "repos/$repo/contents/.github/workflows?ref=$branch" \
             --jq '.[] | select(.type == "file") | .name' 2>/dev/null || true) | sort -u
}

default_branch="$(gh api "repos/$SELF_REPO" --jq '.default_branch' 2>/dev/null || true)"
[ -n "$default_branch" ] || fail "could not resolve the default branch of $SELF_REPO"

main_blob="$(helper_blob_at "$default_branch")"
[ -n "$main_blob" ] || fail "could not read $HELPER_PATH at $default_branch"

problems=0
rows=""
record() { rows="$rows$1"$'\n'; }

while IFS= read -r url; do
  [ -n "$url" ] || continue
  if ! repo="$(repo_from_url "$url")"; then
    record "$(printf '%s\t%s\t%s' "$url" '-' 'unresolvable source url')"
    problems=$((problems + 1)); continue
  fi
  name="${repo##*/}"

  branch="$(gh api "repos/$repo" --jq '.default_branch' 2>/dev/null || true)"
  if [ -z "$branch" ]; then
    record "$(printf '%s\t%s\t%s' "$name" '-' 'UNREADABLE: could not resolve default branch')"
    problems=$((problems + 1)); continue
  fi

  pins="$(consumer_pins "$repo" "$branch")"
  count="$(printf '%s' "$pins" | grep -c . || true)"

  if [ "$count" -eq 0 ]; then
    record "$(printf '%s\t%s\t%s' "$name" '-' 'no announce pin (does not call the shared workflow)')"
    continue
  fi
  if [ "$count" -gt 1 ]; then
    record "$(printf '%s\t%s\t%s' "$name" 'multiple' "AMBIGUOUS: pins $count different shas: $(printf '%s' "$pins" | tr '\n' ' ')")"
    problems=$((problems + 1)); continue
  fi

  blob="$(helper_blob_at "$pins")"
  if [ -z "$blob" ]; then
    record "$(printf '%s\t%s\t%s' "$name" "${pins:0:7}" 'UNREADABLE: pin does not resolve in this repo')"
    problems=$((problems + 1)); continue
  fi
  if [ "$blob" = "$main_blob" ]; then
    record "$(printf '%s\t%s\t%s' "$name" "${pins:0:7}" 'current')"
  else
    record "$(printf '%s\t%s\t%s' "$name" "${pins:0:7}" 'DRIFTED: helper differs from the default branch')"
    problems=$((problems + 1))
  fi
done < <(jq -r '.plugins[]? | .source.url // empty' "$MANIFEST")

printf '%-16s %-9s %s\n' PLUGIN PIN STATUS
printf '%s' "$rows" | while IFS=$'\t' read -r a b c; do
  [ -n "$a" ] || continue
  printf '%-16s %-9s %s\n' "$a" "$b" "$c"
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  # The backticks below are literal markdown for the job summary, not command
  # substitution; single quotes are what keeps them literal.
  # shellcheck disable=SC2016
  {
    printf '## Announce helper pin drift\n\n'
    printf 'Comparing each plugin against `%s` at `%s` (blob `%s`).\n\n' \
      "$HELPER_PATH" "$default_branch" "${main_blob:0:12}"
    printf '| Plugin | Pin | Status |\n|---|---|---|\n'
    printf '%s' "$rows" | while IFS=$'\t' read -r a b c; do
      [ -n "$a" ] || continue
      printf '| %s | `%s` | %s |\n' "$a" "$b" "$c"
    done
    printf '\n'
    if [ "$problems" -eq 0 ]; then
      printf 'Every consumer runs the default branch'"'"'s helper bytes.\n'
    else
      printf '**%s consumer(s) need attention.** A helper fix is not shipped until each one bumps its `uses: ...@<sha>`.\n' "$problems"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$problems" -eq 0 ]; then
  printf '\nfleet current: every consumer runs %s at %s\n' "$HELPER_PATH" "$default_branch"
  exit 0
fi
printf '\n%s consumer(s) stale, ambiguous or unreadable\n' "$problems" >&2
exit 1
