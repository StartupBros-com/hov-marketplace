#!/usr/bin/env bash
set -euo pipefail

# Identity mode is separate from the write, so missing secrets can name every
# manual tag before the workflow attempts to mint an installation token.
if [ "${1:-}" = --identity ]; then
  have_app=false
  if [ -n "${HOV_RELEASE_APP_ID:-}" ] && [ -n "${HOV_RELEASE_APP_PRIVATE_KEY:-}" ]; then have_app=true; fi
  printf 'have_app=%s\n' "$have_app" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
  if [ "$have_app" = false ]; then
    while IFS=$'\t' read -r name version tag sha; do
      [ -z "$tag" ] || printf '::notice::no release App identity; push %s at %s by hand\n' "$tag" "$sha"
    done <"${2:?due.tsv is required}"
  fi
  exit 0
fi

push_url="${PUSH_URL:-}"
if [ -z "$push_url" ]; then
  [ -n "${RELEASE_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] || {
    printf '::error::tag push requires RELEASE_TOKEN and GITHUB_REPOSITORY\n' >&2; exit 1;
  }
  push_url="https://x-access-token:${RELEASE_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
fi
[ "$#" -eq 0 ] || exec <"$1"
failed=0
while IFS=$'\t' read -r name version tag sha; do
  [ -n "$name" ] || continue
  if [ "${DRY_RUN:-0}" = 1 ]; then printf '::notice::would push %s at %s\n' "$tag" "$sha"; continue; fi
  if ! git config user.name >/dev/null; then git config user.name 'github-actions[bot]'; fi
  if ! git config user.email >/dev/null; then git config user.email '41898282+github-actions[bot]@users.noreply.github.com'; fi
  # A failed push can leave the local annotated tag behind. Reuse it only if
  # it still names the intended commit; a rerun must never move a release tag.
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    if [ "$(git rev-list -n 1 "refs/tags/$tag")" != "$sha" ]; then
      printf '::error::local tag %s does not point at %s\n' "$tag" "$sha" >&2; failed=1; continue
    fi
  elif ! git tag -a "$tag" -m "$name v$version" "$sha"; then
    printf '::error::cannot create tag %s at %s\n' "$tag" "$sha" >&2; failed=1; continue
  fi
  # Git errors may include the authenticated URL; never echo their output.
  if git push "$push_url" "refs/tags/$tag" >/dev/null 2>&1; then printf '::notice::pushed %s at %s\n' "$tag" "$sha";
  else printf '::error::could not push tag %s at %s\n' "$tag" "$sha" >&2; failed=1; fi
done
exit "$failed"
