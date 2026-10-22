#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/scripts/plugin-tag.sh
source "$SCRIPT_DIR/plugin-tag.sh"
# The workflow runs the decide step with continue-on-error so valid bumps are still
# tagged, then calls this mode to fail the run for the invalid one.
if [ "${1:-}" = --fail-invalid ]; then
  printf '::error::a VERSION bump was invalid (see the decide step); valid bumps were still tagged\n' >&2; exit 1
fi
plugins_dir="${PLUGINS_DIR:-plugins}"; plugins_dir="${plugins_dir%/}"
parent="${PARENT:-}"; remote="${REMOTE:-origin}"
due=false; failed=0
output_due() { [ -z "${GITHUB_OUTPUT:-}" ] || printf 'due=%s\n' "$due" >>"$GITHUB_OUTPUT"; }
if [ -z "$parent" ] || [[ "$parent" =~ ^0+$ ]] || ! git cat-file -e "$parent^{commit}" 2>/dev/null; then
  if ! parent="$(git rev-parse --verify HEAD^1 2>/dev/null)"; then output_due; exit 0; fi
fi
# A dispatch from a side branch must not manufacture release tags.
if [ -n "${GITHUB_REF_NAME:-}" ] && [ "$GITHUB_REF_NAME" != "${DEFAULT_BRANCH:-main}" ]; then
  printf '::error::auto-release only runs from %s (got %s)\n' "${DEFAULT_BRANCH:-main}" "$GITHUB_REF_NAME" >&2; exit 1
fi
sha="$(git rev-parse HEAD)"
while IFS= read -r -d '' path; do
  relative="${path#"$plugins_dir/"}"; name="${relative%/VERSION}"
  [[ "$name" != */* ]] || continue
  if ! previous="$(git show "$parent:$path" 2>/dev/null)"; then
    printf '::notice::%s was added, not bumped; no tag\n' "$path" >&2; continue
  fi
  [ -f "$path" ] || continue
  version="$(plugin_version_file "$plugins_dir/$name")"
  previous="$(jq -Rrs 'gsub("^\\s+|\\s+$"; "")' <<<"$previous")"
  [ "$version" != "$previous" ] || continue
  if [ ! -f "$plugins_dir/$name/.claude-plugin/plugin.json" ]; then
    printf '::notice::no plugin manifest for %s; nothing to release\n' "$name" >&2; continue
  fi
  valid=true
  if ! is_release_semver "$version"; then printf '::error::%s VERSION %s is not release semver\n' "$name" "$version" >&2; valid=false; fi
  if ! manifest_version="$(plugin_manifest_version "$plugins_dir/$name")" || [ "$manifest_version" != "$version" ]; then
    printf '::error::%s manifest version %s does not match VERSION %s\n' "$name" "${manifest_version:-<unreadable>}" "$version" >&2; valid=false
  fi
  if ! manifest_name="$(plugin_manifest_name "$plugins_dir/$name")" || [ "$manifest_name" != "$name" ]; then
    printf '::error::%s manifest name %s does not match directory\n' "$name" "${manifest_name:-<unreadable>}" >&2; valid=false
  fi
  if [ "$valid" = false ]; then failed=1; continue; fi
  tag="$name--v$version"
  if git ls-remote --exit-code --tags "$remote" "refs/tags/$tag" >/dev/null 2>&1; then
    printf '::notice::%s already exists; nothing to do\n' "$tag" >&2; continue
  else
    status=$?
    if [ "$status" -ne 2 ]; then printf '::error::cannot read remote %s for tag %s\n' "$remote" "$tag" >&2; failed=1; continue; fi
  fi
  printf '%s\t%s\t%s\t%s\n' "$name" "$version" "$tag" "$sha"
  due=true
done < <(git diff --name-only -z "$parent" HEAD -- "$plugins_dir/*/VERSION")
output_due
exit "$failed"
