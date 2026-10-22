#!/usr/bin/env bash
set -euo pipefail

base="${1:-}"; head="${2:-HEAD}"
plugins_dir="${PLUGINS_DIR:-plugins}"; plugins_dir="${plugins_dir%/}"
names=()
add_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || {
    printf '::error::invalid plugin directory name %s\n' "$name" >&2; exit 1;
  }
  [ ! -f "$plugins_dir/$name/.claude-plugin/plugin.json" ] || names+=("$name")
}

if [ -d "$plugins_dir" ]; then
  if [ -z "$base" ] || [[ "$base" =~ ^0+$ ]] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
    printf '::notice::base %s is empty, all zeros, or not a commit here; selecting every plugin\n' "${base:-<empty>}" >&2
    for dir in "$plugins_dir"/*/; do
      [ -f "$dir.claude-plugin/plugin.json" ] || continue
      name="${dir%/}"; add_name "${name##*/}"
    done
  else
    git cat-file -e "$head^{commit}" 2>/dev/null || {
      printf '::error::head %s is not a commit here\n' "$head" >&2; exit 1;
    }
    while IFS= read -r -d '' path; do
      path="${path#"$plugins_dir/"}"
      [[ "$path" == */* ]] || continue
      add_name "${path%%/*}"
    done < <(git diff --name-only --no-renames -z "$base" "$head" -- "$plugins_dir/")
  fi
fi
json="$(jq -cn --args '$ARGS.positional | unique' "${names[@]}")"
printf 'plugins=%s\n' "$json"
if [ "$json" = '[]' ]; then printf 'any=false\n'; else printf 'any=true\n'; fi
