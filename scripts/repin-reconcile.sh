#!/usr/bin/env bash
set -euo pipefail

# Reconcile the marketplace manifest toward what the plugin repositories have
# actually released.
#
# WHY THIS EXISTS
#
# The release chain used to be a sequence of events — merge fires tag, tag fires
# publish, publish fires announce — and event chains cannot be safely re-run. So
# the repos grew defences against retrying instead of making retries harmless
# ("the chain does NOT self-retry past tag creation by design"), and the one step
# no event could perform, updating this manifest, was left to a human following
# docs/plugin-release-recipe.md by hand. Miss it and the release ships
# undistributed.
#
# This script is the opposite shape. It observes two facts — what the plugin has
# released, and what this manifest says — and emits the difference. It performs
# no step "next"; it has no notion of where in a sequence it is. Running it twice
# changes nothing the second time, which is what makes it safe to run on a timer,
# after a failure, or halfway through a botched release.
#
# CREDENTIAL POSTURE
#
# It runs INSIDE hov-marketplace, so the only write is local: a branch and a PR
# in this repository. Reads are public release metadata. That inversion is the
# point — writing this manifest from a plugin repo would need a standing
# cross-repo credential, the one whose compromise reaches every installed client,
# which is exactly why the repin was manual in the first place. Nothing here
# merges: a human still reviews the PR, unchanged.
#
# Usage:
#   scripts/repin-reconcile.sh            # report drift, write PLAN_FILE
#   DRY_RUN=1 scripts/repin-reconcile.sh  # report only, never write the manifest
#
# Env:
#   MANIFEST     path to marketplace.json (default: .claude-plugin/marketplace.json)
#   PLAN_FILE    where to write the TSV plan (default: repin-plan.tsv)
#   ONLY_PLUGIN  restrict to one plugin name (testing / targeted repin)
#   GH_TOKEN     used by gh for release reads
#
# Exit codes:
#   0  manifest already matches every plugin's newest release, or a plan was written
#   1  a read or parse failure — NEVER interpreted as "nothing to do"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

MANIFEST="${MANIFEST:-.claude-plugin/marketplace.json}"
PLAN_FILE="${PLAN_FILE:-repin-plan.tsv}"
DRY_RUN="${DRY_RUN:-0}"
ONLY_PLUGIN="${ONLY_PLUGIN:-}"

[ -s "$MANIFEST" ] || fail "manifest not found: $MANIFEST"

# owner/repo from a canonical card source url. Anything that is not a
# github.com https url is refused rather than guessed: a card we cannot resolve
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

# The newest release for a plugin, INCLUDING drafts. Drafts are deliberately in
# scope: draft-first staging means the release that needs pinning is a draft, and
# its id is exactly what the card must carry before it can be published.
# Prereleases are excluded — they are not what the marketplace distributes.
newest_release() {
  local repo="$1"
  gh api "repos/$repo/releases?per_page=100" --jq '
    [ .[] | select(type == "object")
          | select(.prerelease == false)
          | select((.tag_name | type) == "string" and (.tag_name | length) > 0)
          | select((.id | type) == "number" and .id > 0 and (.id | floor) == .id)
          | {id, tag_name, draft, created_at} ]
    | sort_by(.created_at) | reverse | first // empty
  ' 2>/dev/null
}

plugins="$(jq -r '.plugins[] | select(type == "object") | .name' "$MANIFEST")" \
  || fail "could not read plugin names from $MANIFEST"

: > "$PLAN_FILE"
drift=0
checked=0

while IFS= read -r name; do
  [ -n "$name" ] || continue
  if [ -n "$ONLY_PLUGIN" ] && [ "$name" != "$ONLY_PLUGIN" ]; then
    continue
  fi
  checked=$((checked + 1))

  card="$(jq -ce --arg n "$name" '
      [ .plugins[] | select(type == "object" and .name == $n) ] as $c
      | if ($c | length) != 1 then error("not exactly one card") else $c[0] end
    ' "$MANIFEST")" || fail "manifest does not hold exactly one card for $name"

  url="$(jq -r '.source.url // empty' <<<"$card")"
  [ -n "$url" ] || fail "$name has no source.url"
  repo="$(repo_from_url "$url")" || fail "$name has an unresolvable source.url: $url"

  rel="$(newest_release "$repo")" || fail "could not read releases for $repo"
  if [ -z "$rel" ]; then
    printf 'skip %s: no non-prerelease release yet\n' "$name" >&2
    continue
  fi

  tag="$(jq -r '.tag_name' <<<"$rel")"
  rel_id="$(jq -r '.id' <<<"$rel")"
  is_draft="$(jq -r '.draft' <<<"$rel")"
  version="${tag#v}"

  # Resolve the tag to a commit and require it to be on the default branch, so a
  # tag pushed to a side branch can never be pinned into the distribution manifest.
  sha="$(gh api "repos/$repo/git/ref/tags/${tag}" --jq '.object.sha' 2>/dev/null)" \
    || fail "could not resolve tag $tag in $repo"
  # Annotated tags point at a tag object; dereference to the commit.
  obj_type="$(gh api "repos/$repo/git/ref/tags/${tag}" --jq '.object.type' 2>/dev/null || echo commit)"
  if [ "$obj_type" = tag ]; then
    sha="$(gh api "repos/$repo/git/tags/$sha" --jq '.object.sha' 2>/dev/null)" \
      || fail "could not dereference annotated tag $tag in $repo"
  fi
  default_branch="$(gh api "repos/$repo" --jq '.default_branch' 2>/dev/null)" \
    || fail "could not read the default branch of $repo"
  if ! gh api "repos/$repo/compare/${default_branch}...${sha}" --jq '.status' 2>/dev/null \
       | grep -qE '^(identical|behind)$'; then
    printf 'skip %s: %s (%s) is not an ancestor of %s\n' "$name" "$tag" "${sha:0:8}" "$default_branch" >&2
    continue
  fi

  card_version="$(jq -r '.metadata.version // ""' <<<"$card")"
  card_tag="$(jq -r '.metadata.releaseTag // ""' <<<"$card")"
  card_id="$(jq -r '.metadata.releaseId // ""' <<<"$card")"
  card_sha="$(jq -r '.source.sha // ""' <<<"$card")"

  if [ "$card_version" = "$version" ] && [ "$card_tag" = "$tag" ] \
     && [ "$card_id" = "$rel_id" ] && [ "$card_sha" = "$sha" ]; then
    continue
  fi

  drift=$((drift + 1))
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$version" "$tag" "$rel_id" "$sha" "$is_draft" >> "$PLAN_FILE"
  printf 'drift %s: card %s (%s) -> release %s (%s, draft=%s)\n' \
    "$name" "${card_tag:-none}" "${card_id:-none}" "$tag" "$rel_id" "$is_draft" >&2
done <<<"$plugins"

if [ "$drift" -eq 0 ]; then
  printf 'checked %s plugin(s): manifest already matches every newest release\n' "$checked"
  rm -f "$PLAN_FILE"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  printf 'checked %s plugin(s): %s need a repin (dry run, manifest untouched)\n' "$checked" "$drift"
  exit 0
fi

# Apply every drifting card in one pass. -a keeps the manifest's existing
# \uXXXX escaping and --indent 2 its layout, so the diff is only the fields that
# actually changed; a formatting rewrite here would touch every plugin's card and
# bury the real change.
tmp="$(mktemp)"
cp "$MANIFEST" "$tmp"
while IFS=$'\t' read -r name version tag rel_id sha _draft; do
  [ -n "$name" ] || continue
  jq -a --indent 2 \
    --arg n "$name" --arg v "$version" --arg t "$tag" --arg s "$sha" --argjson i "$rel_id" '
      .plugins |= map(
        if type == "object" and .name == $n then
          .metadata.version = $v
          | .metadata.releaseTag = $t
          | .metadata.releaseId = $i
          | .source.sha = $s
        else . end
      )
    ' "$tmp" > "$tmp.next" || fail "failed to update the card for $name"
  mv "$tmp.next" "$tmp"
done < "$PLAN_FILE"

mv "$tmp" "$MANIFEST"
printf 'checked %s plugin(s): repinned %s\n' "$checked" "$drift"
