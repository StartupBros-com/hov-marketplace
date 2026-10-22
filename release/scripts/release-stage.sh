#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/scripts/plugin-tag.sh
source "$SCRIPT_DIR/plugin-tag.sh"
tag="${RELEASE_TAG:-}"; plugins="${PLUGINS_DIR:-plugins}"; branch="${DEFAULT_BRANCH:-main}"; remote="${REMOTE:-origin}"
fail() { printf '::error::%s\n' "$*" >&2; exit 1; }
name="$(tag_plugin_name "$tag")" || fail "$tag is not a <name>--v<version> tag"
version="$(tag_plugin_version "$tag")"; dir="$plugins/$name"
[ -f "$dir/.claude-plugin/plugin.json" ] || fail "unknown plugin $name: no $dir/ at $tag"
sha="$(git rev-list -n 1 "refs/tags/$tag" 2>/dev/null)" || fail "tag $tag does not exist"
[ "$(git rev-parse HEAD)" = "$sha" ] || fail "checkout HEAD is not $tag ($sha)"
git fetch "$remote" "$branch" || fail "could not fetch $remote/$branch for $tag"
commit_on_branch "$sha" "$remote/$branch" || fail "$tag ($sha) is not on $branch; refusing to stage a release from a side branch"
current="$(plugin_version_file "$dir")" || fail "$tag cannot read $dir/VERSION"
is_release_semver "$current" || fail "$tag VERSION $current is not release semver"
[ "$version" = "$current" ] || fail "tag $tag does not match VERSION $current"
manifest_version="$(plugin_manifest_version "$dir")" || fail "$tag cannot read manifest version"
[ "$manifest_version" = "$version" ] || fail "$tag manifest version $manifest_version does not match VERSION $current"
manifest_name="$(plugin_manifest_name "$dir")" || fail "$tag cannot read manifest name"
[ "$manifest_name" = "$name" ] || fail "$tag manifest name $manifest_name does not match plugin $name"
notes="$dir/docs/release-notes/v$version.md"
[ -f "$notes" ] || fail "$tag requires release notes $notes"
"$SCRIPT_DIR/check-release-notes.sh" "$notes" || fail "$tag release notes failed: $notes"
if state="$(gh release view "$tag" --json id,isDraft 2>/dev/null)"; then
  printf '::notice::release %s already exists (id %s, draft %s); nothing to stage\n' "$tag" "$(jq -r .id <<<"$state")" "$(jq -r .isDraft <<<"$state")"
  exit 0
fi
"$SCRIPT_DIR/release-gate.sh" "$name" "$sha" || fail "$tag CI release gate failed on $sha"
gh release create "$tag" --draft --verify-tag --title "$name v$version" --notes-file "$notes" || fail "could not stage draft $tag"
id="$(gh release view "$tag" --json id --jq .id)" || fail "could not read staged draft $tag id"
printf '::notice::staged draft %s (id %s)\n' "$tag" "$id"
