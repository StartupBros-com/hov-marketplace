#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-syntax}"
MANIFEST="${MARKETPLACE_MANIFEST:-.claude-plugin/marketplace.json}"
BASE_REF="${BASE_REF:-}"
EXPECTED_PLUGIN_NAME="${EXPECTED_PLUGIN_NAME:-}"
EXPECTED_PLUGIN_VERSION="${EXPECTED_PLUGIN_VERSION:-}"
EXPECTED_RELEASE_ID="${EXPECTED_RELEASE_ID:-}"
EXPECTED_RELEASE_TAG="${EXPECTED_RELEASE_TAG:-}"
EXPECTED_SHA="${EXPECTED_SHA:-}"
EXPECTED_PAYLOAD_PATHS="${EXPECTED_PAYLOAD_PATHS:-}"
ALLOW_LOCAL_FILE_REMOTES="${ALLOW_LOCAL_FILE_REMOTES:-0}"
MARKETPLACE_TEST_REMOTE_ROOT="${MARKETPLACE_TEST_REMOTE_ROOT:-}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

is_semver() {
  jq -en --arg value "$1" '$value | test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*)|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\\.((0|[1-9][0-9]*)|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$")' >/dev/null
}

is_uint() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]
}

semver_gt() {
  local left_major left_minor left_patch right_major right_minor right_patch
  IFS=. read -r left_major left_minor left_patch <<<"${1%%[-+]*}"
  IFS=. read -r right_major right_minor right_patch <<<"${2%%[-+]*}"
  (( left_major > right_major )) ||
    (( left_major == right_major && left_minor > right_minor )) ||
    (( left_major == right_major && left_minor == right_minor && left_patch > right_patch ))
}

expected_source_url() {
  case "$1" in
    token-eater) printf '%s\n' 'https://github.com/StartupBros-com/token-eater.git' ;;
    pro-gate) printf '%s\n' 'https://github.com/StartupBros-com/pro-gate.git' ;;
    *) return 1 ;;
  esac
}

validate_expected_inputs() {
  local value
  for value in "$EXPECTED_PLUGIN_VERSION" "$EXPECTED_RELEASE_ID" "$EXPECTED_RELEASE_TAG" "$EXPECTED_SHA" "$EXPECTED_PAYLOAD_PATHS"; do
    if [[ -n "$value" && -z "$EXPECTED_PLUGIN_NAME" ]]; then
      fail "EXPECTED_PLUGIN_NAME is required with expected plugin or release metadata"
    fi
  done
  [[ -z "$EXPECTED_PLUGIN_VERSION" ]] || is_semver "$EXPECTED_PLUGIN_VERSION" || fail "EXPECTED_PLUGIN_VERSION is not semver"
  [[ -z "$EXPECTED_RELEASE_ID" ]] || is_uint "$EXPECTED_RELEASE_ID" || fail "EXPECTED_RELEASE_ID is not an unsigned integer"
  [[ -z "$EXPECTED_RELEASE_TAG" || -z "$EXPECTED_PLUGIN_VERSION" || "$EXPECTED_RELEASE_TAG" == "v$EXPECTED_PLUGIN_VERSION" ]] || fail "expected release tag does not match expected plugin version"
  [[ -z "$EXPECTED_SHA" || "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "EXPECTED_SHA must be a full lowercase commit SHA"
}

validate_shape() {
  jq -e '
    type == "object" and
    ([keys[]] - ["name", "owner", "metadata", "plugins"] | length == 0) and
    (.name | type == "string" and length > 0) and
    (.owner | type == "object") and
    (.owner | keys | sort == ["name", "url"]) and
    (.owner.name | type == "string" and length > 0) and
    (.owner.url | type == "string" and test("^https://[^[:space:]]+$")) and
    (.metadata | type == "object") and
    (.metadata | keys | sort == ["description", "version"]) and
    (.metadata.description | type == "string" and length > 0) and
    (.metadata.version | type == "string") and
    (.plugins | type == "array" and length > 0) and
    all(.plugins[];
      type == "object" and
      ([keys[]] - ["name", "source", "description", "metadata"] | length == 0) and
      (.name | type == "string" and test("^[a-z0-9]+([.-][a-z0-9]+)*$")) and
      (.description | type == "string" and length > 0) and
      (.source | type == "object") and
      (.source | keys | sort == ["sha", "source", "url"]) and
      (.source.source == "url") and
      (.source.url | type == "string" and test("^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\\.git$")) and
      (.source.sha | type == "string" and test("^[0-9a-f]{40}$")) and
      ((has("metadata") | not) or
        (.metadata | type == "object") and
        ([.metadata | keys[]] - ["version", "releaseId", "releaseTag"] | length == 0) and
        (.metadata.version | type == "string") and
        (.metadata.releaseId | type == "number" and floor == . and . >= 0) and
        (.metadata.releaseTag | type == "string")))
  ' "$MANIFEST" >/dev/null || fail "marketplace manifest has an invalid shape"

  local marketplace_version
  marketplace_version="$(jq -r '.metadata.version' "$MANIFEST")"
  is_semver "$marketplace_version" || fail "marketplace metadata.version is not semver"

  local duplicates
  duplicates="$(jq -r '[.plugins[].name] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' "$MANIFEST")"
  [[ -z "$duplicates" ]] || fail "plugin names must be unique: $duplicates"

  while IFS=$'\t' read -r name url version release_id release_tag; do
    local approved_url
    approved_url="$(expected_source_url "$name")" || fail "plugin $name is not approved for this marketplace"
    [[ "$url" == "$approved_url" ]] || fail "plugin $name must use approved source $approved_url"
    [[ -z "$version" ]] && continue
    is_semver "$version" || fail "plugin $name metadata.version is not semver"
    is_uint "$release_id" || fail "plugin $name metadata.releaseId is not an unsigned integer"
    [[ "$release_tag" == "v$version" ]] || fail "plugin $name metadata.releaseTag does not match metadata.version"
  done < <(jq -r '.plugins[] | [.name, .source.url, (.metadata.version // ""), (.metadata.releaseId // "" | tostring), (.metadata.releaseTag // "")] | @tsv' "$MANIFEST")
}

validate_expected_entry() {
  [[ -n "$EXPECTED_PLUGIN_NAME" ]] || return 0
  local count
  count="$(jq --arg name "$EXPECTED_PLUGIN_NAME" '[.plugins[] | select(.name == $name)] | length' "$MANIFEST")"
  [[ "$count" == 1 ]] || fail "expected plugin $EXPECTED_PLUGIN_NAME is not present exactly once"

  local actual
  if [[ -n "$EXPECTED_PLUGIN_VERSION" ]]; then
    actual="$(jq -r --arg name "$EXPECTED_PLUGIN_NAME" '.plugins[] | select(.name == $name) | .metadata.version // empty' "$MANIFEST")"
    [[ "$actual" == "$EXPECTED_PLUGIN_VERSION" ]] || fail "plugin $EXPECTED_PLUGIN_NAME version mismatch: expected $EXPECTED_PLUGIN_VERSION, got ${actual:-missing}"
  fi
  if [[ -n "$EXPECTED_RELEASE_ID" ]]; then
    actual="$(jq -r --arg name "$EXPECTED_PLUGIN_NAME" '.plugins[] | select(.name == $name) | .metadata.releaseId // empty' "$MANIFEST")"
    [[ "$actual" == "$EXPECTED_RELEASE_ID" ]] || fail "plugin $EXPECTED_PLUGIN_NAME release id mismatch: expected $EXPECTED_RELEASE_ID, got ${actual:-missing}"
  fi
  if [[ -n "$EXPECTED_RELEASE_TAG" ]]; then
    actual="$(jq -r --arg name "$EXPECTED_PLUGIN_NAME" '.plugins[] | select(.name == $name) | .metadata.releaseTag // empty' "$MANIFEST")"
    [[ "$actual" == "$EXPECTED_RELEASE_TAG" ]] || fail "plugin $EXPECTED_PLUGIN_NAME release tag mismatch: expected $EXPECTED_RELEASE_TAG, got ${actual:-missing}"
  fi
  if [[ -n "$EXPECTED_SHA" ]]; then
    actual="$(jq -r --arg name "$EXPECTED_PLUGIN_NAME" '.plugins[] | select(.name == $name) | .source.sha' "$MANIFEST")"
    [[ "$actual" == "$EXPECTED_SHA" ]] || fail "plugin $EXPECTED_PLUGIN_NAME SHA mismatch: expected $EXPECTED_SHA, got $actual"
  fi
}

validate_monotonicity() {
  [[ -n "$BASE_REF" ]] || return 0
  local base_manifest
  base_manifest="$(mktemp)"
  trap 'rm -f "${base_manifest:-}"' RETURN
  git show "$BASE_REF:$MANIFEST" >"$base_manifest" 2>/dev/null || fail "could not read $MANIFEST from BASE_REF $BASE_REF"
  jq -e . "$base_manifest" >/dev/null 2>&1 || fail "base marketplace manifest is malformed"

  while IFS=$'\t' read -r name current_id base_id current_version base_version current_sha base_sha current_tag base_tag current_url base_url; do
    [[ -n "$current_id" ]] || fail "plugin $name removed release metadata present at $BASE_REF"
    is_uint "$current_id" && is_uint "$base_id" || fail "plugin $name has non-numeric release metadata"
    (( current_id >= base_id )) || fail "plugin $name releaseId rolled back from $base_id to $current_id"
    if (( current_id == base_id )); then
      [[ "$current_version|$current_sha|$current_tag|$current_url" == "$base_version|$base_sha|$base_tag|$base_url" ]] || fail "plugin $name changed immutable metadata for releaseId $current_id"
    else
      semver_gt "$current_version" "$base_version" || fail "plugin $name version must increase when releaseId advances"
    fi
  done < <(jq -r --slurpfile current "$MANIFEST" '.plugins[] | select(.metadata.releaseId != null) | .name as $name | ($current[0].plugins[] | select(.name == $name)) as $now | [$name, ($now.metadata.releaseId // "" | tostring), (.metadata.releaseId | tostring), ($now.metadata.version // ""), (.metadata.version // ""), $now.source.sha, .source.sha, ($now.metadata.releaseTag // ""), (.metadata.releaseTag // ""), $now.source.url, .source.url] | @tsv' "$base_manifest")

  while IFS=$'\t' read -r name current_id base_id; do
    [[ -n "$base_id" ]] && continue
    is_uint "$current_id" || fail "plugin $name has non-numeric release metadata"
  done < <(jq -r --slurpfile base "$base_manifest" '.plugins[] | select(.metadata.releaseId != null) | .name as $name | [$name, (.metadata.releaseId | tostring), (($base[0].plugins[] | select(.name == $name) | .metadata.releaseId) // "" | tostring)] | @tsv' "$MANIFEST")
  rm -f "$base_manifest"
  trap - RETURN
  base_manifest=""
}

remote_for_url() {
  local url="$1"
  if [[ -z "$MARKETPLACE_TEST_REMOTE_ROOT" ]]; then
    printf '%s\n' "$url"
    return
  fi
  [[ "$ALLOW_LOCAL_FILE_REMOTES" == 1 ]] || fail "MARKETPLACE_TEST_REMOTE_ROOT requires ALLOW_LOCAL_FILE_REMOTES=1"
  local slug="${url#https://github.com/}"
  slug="${slug%.git}"
  local remote="$MARKETPLACE_TEST_REMOTE_ROOT/$slug.git"
  [[ -d "$remote" ]] || remote="$MARKETPLACE_TEST_REMOTE_ROOT/$slug"
  [[ -d "$remote" ]] || fail "local test remote not found for $url"
  printf '%s\n' "$remote"
}

validate_remote_plugin() {
  local name="$1" url="$2" sha="$3" metadata_version="$4" metadata_tag="$5"
  local remote repo manifest_json manifest_name manifest_version resolved_tag
  remote="$(remote_for_url "$url")"
  repo="$(mktemp -d)"
  git -C "$repo" init -q
  if ! git -C "$repo" fetch -q --depth=1 "$remote" "$sha"; then
    rm -rf "$repo"
    fail "plugin $name pinned commit is not reachable from $url"
  fi
  git -C "$repo" cat-file -e FETCH_HEAD^{commit} 2>/dev/null || { rm -rf "$repo"; fail "plugin $name pin is not a commit"; }
  [[ "$(git -C "$repo" rev-parse FETCH_HEAD)" == "$sha" ]] || { rm -rf "$repo"; fail "plugin $name fetched commit does not match its pin"; }

  manifest_json="$(git -C "$repo" show FETCH_HEAD:.claude-plugin/plugin.json 2>/dev/null)" || { rm -rf "$repo"; fail "plugin $name pin has no .claude-plugin/plugin.json"; }
  jq -e 'type == "object" and (.name | type == "string" and length > 0) and (.version | type == "string" and length > 0)' <<<"$manifest_json" >/dev/null || { rm -rf "$repo"; fail "plugin $name pinned manifest has an invalid shape"; }
  manifest_name="$(jq -r '.name' <<<"$manifest_json")"
  manifest_version="$(jq -r '.version' <<<"$manifest_json")"
  [[ "$manifest_name" == "$name" ]] || { rm -rf "$repo"; fail "plugin $name pinned manifest name is $manifest_name"; }
  is_semver "$manifest_version" || { rm -rf "$repo"; fail "plugin $name pinned manifest version is not semver"; }
  [[ -z "$metadata_version" || "$manifest_version" == "$metadata_version" ]] || { rm -rf "$repo"; fail "plugin $name marketplace and pinned manifest versions differ"; }
  git -C "$repo" cat-file -e "FETCH_HEAD:skills/$name/SKILL.md" 2>/dev/null || { rm -rf "$repo"; fail "plugin $name pin is missing skills/$name/SKILL.md"; }

  if [[ -n "$metadata_tag" ]]; then
    resolved_tag="$(git ls-remote "$remote" "refs/tags/$metadata_tag^{}" | jq -Rrs 'split("\n") | map(select(length > 0) | split("\t")[0]) | first // empty')"
    [[ -n "$resolved_tag" ]] || resolved_tag="$(git ls-remote "$remote" "refs/tags/$metadata_tag" | jq -Rrs 'split("\n") | map(select(length > 0) | split("\t")[0]) | first // empty')"
    [[ "$resolved_tag" == "$sha" ]] || { rm -rf "$repo"; fail "plugin $name release tag does not resolve to its pinned commit"; }
  fi

  if [[ "$name" == "$EXPECTED_PLUGIN_NAME" && -n "$EXPECTED_PAYLOAD_PATHS" ]]; then
    local path
    IFS=',' read -r -a paths <<<"$EXPECTED_PAYLOAD_PATHS"
    for path in "${paths[@]}"; do
      [[ -n "$path" && "$path" != /* && "$path" != *..* ]] || { rm -rf "$repo"; fail "invalid expected payload path: $path"; }
      git -C "$repo" cat-file -e "FETCH_HEAD:$path" 2>/dev/null || { rm -rf "$repo"; fail "plugin $name pin is missing expected payload $path"; }
    done
  fi
  rm -rf "$repo"
}

validate_full() {
  while IFS=$'\t' read -r name url sha version tag; do
    validate_remote_plugin "$name" "$url" "$sha" "$version" "$tag"
  done < <(jq -r '.plugins[] | [.name, .source.url, .source.sha, (.metadata.version // ""), (.metadata.releaseTag // "")] | @tsv' "$MANIFEST")
}

[[ "$MODE" == syntax || "$MODE" == full ]] || fail "usage: $0 [syntax|full]"
require_command jq
require_command git
[[ -f "$MANIFEST" ]] || fail "marketplace manifest not found: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null 2>&1 || fail "marketplace manifest is malformed JSON"
validate_expected_inputs
validate_shape
validate_expected_entry
validate_monotonicity
[[ "$MODE" == syntax ]] || validate_full
printf 'marketplace validation passed (%s)\n' "$MODE"
