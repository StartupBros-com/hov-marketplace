#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/scripts/plugin-tag.sh
source "$SCRIPT_DIR/plugin-tag.sh"
tag="${RELEASE_TAG:-}"; branch="${DEFAULT_BRANCH:-main}"; remote="${REMOTE:-origin}"; plugins="${PLUGINS_DIR:-plugins}"
fail() { printf '::error::%s\n' "$*" >&2; exit 1; }
name="$(tag_plugin_name "$tag")" || fail "$tag is not a <name>--v<version> tag"
sha="$(git rev-list -n 1 "refs/tags/$tag" 2>/dev/null)" || fail "tag $tag does not exist"
git fetch "$remote" "$branch" || fail "could not fetch $remote/$branch for $tag"
commit_on_branch "$sha" "$remote/$branch" || fail "$tag ($sha) is not on $branch"
file="$plugins/$name/.claude-plugin/plugin.json"
manifest="$(git show "$sha:$file" 2>/dev/null)" || fail "$tag has no plugin manifest $file"
manifest_name="$(jq -er '.name' <<<"$manifest")" || fail "$tag cannot read manifest name from $file"
[ "$manifest_name" = "$name" ] || fail "$tag manifest name $manifest_name does not match plugin $name"
printf 'ok - %s (%s) is on %s and names plugin %s\n' "$tag" "$sha" "$branch" "$name"
