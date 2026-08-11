#!/usr/bin/env bash
set -euo pipefail

# Generalized announce-only Tool Drop train, called by the reusable workflow
# .github/workflows/hov-tool-drop-announce.yml for EVERY catalog plugin.
#
# The marketplace manifest in this repo is the single source of truth: a
# release announces only when the manifest already lists this exact release
# tuple AND carries a card block for the plugin. This script never writes to
# the marketplace (repins are reviewed PRs) and holds no deploy key.
#
# Auth: a GitHub Actions OIDC token (Authorization: Bearer) minted only after
# every preflight passes. Its audience binds the token to the SHA-256 digest of
# the exact request bytes sent to the one fixed Tool Drop endpoint.
#
# Soft exits (loud in the run UI, green in the checks list): marketplace not
# yet repinned to this release, or no card block registered — both resolve
# with a marketplace PR, then editing the release re-fires the announce.

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

readonly TOOL_RELEASES_ENDPOINT='https://members.startupbros.com/api/internal/ops/tool-releases'
# Six current caller repositories, one inherited same-release lease, and one
# spare bounded window can all clear without turning a transient queue into loss.
readonly ANNOUNCE_MAX_ATTEMPTS=8
readonly RETRY_LEASE_EXPIRY_CUSHION_SECONDS=2
readonly RETRY_JITTER_MAX_SECONDS=3
readonly RESPONSE_CONTEXT_MAX_BYTES=2048

ANNOUNCE_RESPONSE_DIR=''

cleanup_response_dir() {
  local -r response_dir="${ANNOUNCE_RESPONSE_DIR:-}"
  [[ -n "$response_dir" ]] || return 0
  rm -f -- "$response_dir/response-body" "$response_dir/response-headers"
  rmdir -- "$response_dir"
  ANNOUNCE_RESPONSE_DIR=''
}

require() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "$name is required"
}

is_positive_uint() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

load_current_release() {
  require CURRENT_RELEASE_FILE
  local current_release

  if ! current_release="$(jq -ces \
    --arg expected_id "$RELEASE_ID" \
    --arg expected_tag "$RELEASE_TAG" \
    '
      if length == 1 and
        (.[0] |
          type == "object" and
          has("id") and
          (.id | type == "number") and
          (.id > 0) and
          (.id == (.id | floor)) and
          ((.id | tostring) == $expected_id) and
          has("tag_name") and
          (.tag_name | type == "string") and
          (.tag_name | length > 0) and
          (.tag_name == $expected_tag) and
          has("body") and
          (.body == null or (.body | type == "string")) and
          has("draft") and
          (.draft | type == "boolean") and
          has("prerelease") and
          (.prerelease | type == "boolean"))
      then .[0]
      else error("current release record failed validation")
      end
    ' -- "$CURRENT_RELEASE_FILE")"; then
    fail "current release record is invalid or does not match expected identity"
  fi

  CURRENT_RELEASE_NOTES="$(jq -jr 'if .body == null then "" else .body end' <<<"$current_release")"
  CURRENT_RELEASE_DRAFT="$(jq -r '.draft' <<<"$current_release")"
  CURRENT_RELEASE_PRERELEASE="$(jq -r '.prerelease' <<<"$current_release")"
  readonly CURRENT_RELEASE_NOTES CURRENT_RELEASE_DRAFT CURRENT_RELEASE_PRERELEASE
}

notes_summary() {
  # Card-ready release bullets. Preference order: author-written "## Highlights"
  # section; GitHub's auto "What's Changed" bullets, cleaned; first paragraph.
  # Up to 3 bullets, each <=180 chars, total <=600.
  local notes bullets
  notes="$(printf '%s' "${CURRENT_RELEASE_NOTES:-}" | tr -d '\r')"
  [[ -n "$notes" ]] || return 0
  bullets="$(printf '%s\n' "$notes" | sed -n '/^##[[:space:]]*Highlights/,/^## /p' | grep -E '^[*•-][[:space:]]' || true)"
  if [[ -z "$bullets" ]]; then
    if grep -qE '^##[[:space:]]*What.?.?s Changed' <<<"$notes"; then
      bullets="$(printf '%s\n' "$notes" | sed -n '/^##[[:space:]]*What.\{0,2\}s Changed/,/^## /p' | grep -E '^\*[[:space:]]' || true)"
    elif [[ "$(awk 'NF { print; exit }' <<<"$notes")" == \** ]]; then
      bullets="$(awk '/^[[:space:]]*$/{exit} /^\*[[:space:]]/{print}' <<<"$notes")"
    fi
  fi
  if [[ -n "$bullets" ]]; then
    # Character-safe slicing: cut -c is BYTES under GNU coreutils and can split
    # multibyte characters; python3 is guaranteed on the Actions runner.
    printf '%s\n' "$bullets" \
      | sed -E 's/^[*•-][[:space:]]+//; s/[[:space:]]+by @[A-Za-z0-9_[:punct:]]+ in http[^[:space:]]*[[:space:]]*$//; s/^(feat|fix|perf|chore|docs|refactor|test|ci|build)(\([^)]*\))?!?:[[:space:]]*//; s/[[:space:]]*\(v[0-9]+\.[0-9]+\.[0-9]+\)[[:space:]]*$//' \
      | python3 -c 'import sys

def utf16_prefix(value, limit):
    used = 0
    out = []
    for char in value:
        width = 2 if ord(char) > 0xFFFF else 1
        if used + width > limit:
            break
        out.append(char)
        used += width
    return "".join(out)

out = []
for line in sys.stdin.read().splitlines():
    line = line.strip()
    if line:
        out.append(utf16_prefix(line, 180))
    if len(out) == 3:
        break
print(utf16_prefix("\n".join(out), 600))'
    return 0
  fi
  # Prose fallback: the drop card gets an excerpt instead of a what's-new list.
  # Warn loudly so a degraded card is visible in the release run.
  printf '::warning title=No release highlights::%s %s has no "## Highlights" bullets; the drop card falls back to a prose excerpt. See docs/plugin-release-recipe.md.\n' \
    "${REPOSITORY:-plugin}" "${RELEASE_TAG:-release}" >&2
  printf '%s' "$notes" \
    | awk 'BEGIN{RS=""} NR==1' \
    | tr '\n' ' ' \
    | python3 -c 'import sys
value = sys.stdin.read()
used = 0
out = []
for char in value:
    width = 2 if ord(char) > 0xFFFF else 1
    if used + width > 600:
        break
    out.append(char)
    used += width
print("".join(out), end="")'
}

sha256_bytes() {
  local digest
  digest="$(printf '%s' "$1" | sha256sum)"
  digest="${digest%% *}"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "could not compute request body SHA-256"
  printf '%s\n' "$digest"
}

retry_jitter_seconds() {
  local -r jitter_repository="$1" jitter_release_id="$2" jitter_attempt="$3"
  local digest
  digest="$(sha256_bytes "$jitter_repository:$jitter_release_id:$jitter_attempt")"
  printf '%d\n' "$((16#${digest:0:8} % (RETRY_JITTER_MAX_SECONDS + 1)))"
}

mint_oidc_token() {
  local -r audience="$1"
  require ACTIONS_ID_TOKEN_REQUEST_URL
  require ACTIONS_ID_TOKEN_REQUEST_TOKEN
  curl --disable --fail-with-body --silent --show-error --get \
    -H "authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    --data-urlencode "audience=$audience" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL" \
    | jq -er '.value | select(type == "string" and length > 0)'
}

report_response_context() {
  local -r message="$1" response_body="$2"
  local body_size
  printf 'error: %s\n' "$message" >&2
  if [[ ! -s "$response_body" ]]; then
    printf 'response body: <empty>\n' >&2
    return
  fi

  body_size="$(wc -c <"$response_body")"
  body_size="${body_size//[[:space:]]/}"
  printf 'response body (first %d bytes):\n' "$RESPONSE_CONTEXT_MAX_BYTES" >&2
  head -c "$RESPONSE_CONTEXT_MAX_BYTES" "$response_body" >&2
  if ((body_size > RESPONSE_CONTEXT_MAX_BYTES)); then
    printf '\n... response body truncated ...\n' >&2
  else
    printf '\n' >&2
  fi
}

retry_after_seconds() {
  local -r response_headers="$1" expected_status="$2"
  local line value final_status='' in_header_block=false saw_folded_line=false
  local -a values=()

  [[ "$expected_status" == 409 || "$expected_status" == 429 ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^HTTP/[0-9]+(\.[0-9]+)?[[:blank:]]+([0-9][0-9][0-9])([[:blank:]].*)?$ ]]; then
      final_status="${BASH_REMATCH[2]}"
      values=()
      in_header_block=true
      saw_folded_line=false
      continue
    fi
    if [[ -z "$line" ]]; then
      in_header_block=false
      continue
    fi
    if [[ "$in_header_block" == true && "$line" == [[:blank:]]* ]]; then
      saw_folded_line=true
      continue
    fi
    if [[ "$in_header_block" == true && "${line,,}" == retry-after:* ]]; then
      value="${line#*:}"
      value="${value#"${value%%[![:blank:]]*}"}"
      value="${value%"${value##*[![:blank:]]}"}"
      values+=("$value")
    fi
  done <"$response_headers"

  [[ "$final_status" == "$expected_status" ]] || return 1
  [[ "$saw_folded_line" == false ]] || return 1
  [[ ${#values[@]} -eq 1 ]] || return 1
  [[ "${values[0]}" =~ ^([1-9]|[1-9][0-9]|[1-5][0-9][0-9]|600)$ ]] || return 1
  printf '%s\n' "${values[0]}"
}

send_request() {
  local -r request_body="$1" expected_sha="$2" oidc_token="$3"
  local -r response_body="$4" response_headers="$5" http_status_name="$6"
  local actual_sha curl_http_code curl_exit=0

  : >"$response_body"
  : >"$response_headers"
  actual_sha="$(sha256_bytes "$request_body")"
  [[ "$actual_sha" == "$expected_sha" ]] || fail "request body changed after OIDC mint"

  curl_http_code="$(curl --disable --silent --show-error \
    --request POST \
    -H 'content-type: application/json' \
    -H "authorization: Bearer $oidc_token" \
    --data-binary "$request_body" \
    --output "$response_body" \
    --dump-header "$response_headers" \
    --write-out '%{http_code}' \
    "$TOOL_RELEASES_ENDPOINT")" || curl_exit=$?
  printf -v "$http_status_name" '%s' "$curl_http_code"

  if ((curl_exit != 0)); then
    report_response_context "Tool Drop POST transport failure (curl exit $curl_exit)" "$response_body"
    return 1
  fi
  if [[ ! "$curl_http_code" =~ ^[0-9][0-9][0-9]$ ]]; then
    report_response_context "Tool Drop POST returned an invalid HTTP status" "$response_body"
    return 1
  fi
}

announce() {
  local notes request_body request_sha audience oidc_token
  local response_body response_headers http_status retry_after retry_delay retry_jitter
  local attempt result=1
  notes="$(notes_summary)"
  request_body="$(jq -cn \
    --arg operation announce \
    --arg repository "$REPOSITORY" \
    --arg releaseId "$RELEASE_ID" \
    --arg notesSummary "$notes" \
    '{operation: $operation, repository: $repository, releaseId: $releaseId} + (if $notesSummary == "" then {} else {notesSummary: $notesSummary} end)')"
  readonly request_body
  request_sha="$(sha256_bytes "$request_body")"
  audience="${TOOL_RELEASES_ENDPOINT}#sha256=$request_sha"
  readonly request_sha audience

  ANNOUNCE_RESPONSE_DIR="$(mktemp -d)" || fail "could not create response capture directory"
  response_body="$ANNOUNCE_RESPONSE_DIR/response-body"
  response_headers="$ANNOUNCE_RESPONSE_DIR/response-headers"
  trap cleanup_response_dir EXIT

  for ((attempt = 1; attempt <= ANNOUNCE_MAX_ATTEMPTS; attempt += 1)); do
    http_status=''
    if ! oidc_token="$(mint_oidc_token "$audience")"; then
      fail "could not mint OIDC token"
    fi
    printf '::add-mask::%s\n' "$oidc_token"
    if ! send_request "$request_body" "$request_sha" "$oidc_token" \
      "$response_body" "$response_headers" http_status; then
      break
    fi

    if [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
      command cat "$response_body"
      result=0
      break
    fi
    if [[ "$http_status" != 409 && "$http_status" != 429 ]]; then
      report_response_context "Tool Drop POST failed with HTTP $http_status" "$response_body"
      break
    fi
    if ! retry_after="$(retry_after_seconds "$response_headers" "$http_status")"; then
      report_response_context "HTTP $http_status lacked one canonical Retry-After value from 1 through 600" "$response_body"
      break
    fi
    if ((attempt == ANNOUNCE_MAX_ATTEMPTS)); then
      report_response_context "Tool Drop POST exhausted $ANNOUNCE_MAX_ATTEMPTS attempts (last HTTP $http_status)" "$response_body"
      break
    fi

    retry_jitter="$(retry_jitter_seconds "$REPOSITORY" "$RELEASE_ID" "$attempt")"
    retry_delay=$((10#$retry_after + RETRY_LEASE_EXPIRY_CUSHION_SECONDS + retry_jitter))
    sleep "$retry_delay"
  done

  cleanup_response_dir
  trap - EXIT
  return "$result"
}

verify_release() {
  require SOURCE_ROOT
  require SOURCE_SHA
  local version manifest_version expected_tag
  version="$(tr -d '[:space:]' < "$SOURCE_ROOT/VERSION")"
  manifest_version="$(jq -er '.version' "$SOURCE_ROOT/.claude-plugin/plugin.json")"
  expected_tag="v$version"
  [[ "$RELEASE_TAG" == "$expected_tag" ]] || fail "release tag $RELEASE_TAG does not match VERSION $version"
  [[ "$manifest_version" == "$version" ]] || fail "plugin manifest version $manifest_version does not match VERSION $version"
  [[ "$(git -C "$SOURCE_ROOT" rev-parse HEAD)" == "$SOURCE_SHA" ]] || fail "checked-out source does not match release commit"
  [[ "$(git -C "$SOURCE_ROOT" rev-list -n 1 "refs/tags/$RELEASE_TAG")" == "$SOURCE_SHA" ]] || fail "release tag does not resolve to the exact release commit"
  printf '%s\n' "$version"
}

marketplace_lists_release() {
  require MARKETPLACE_MANIFEST
  jq -e \
    --arg name "$REPOSITORY" \
    --arg sha "$SOURCE_SHA" \
    --arg version "$RELEASE_VERSION" \
    --argjson release_id "$RELEASE_ID" \
    --arg release_tag "$RELEASE_TAG" \
    'any(.plugins[]; .name == $name and .source.sha == $sha and .metadata.version == $version and .metadata.releaseId == $release_id and .metadata.releaseTag == $release_tag)' \
    "$MARKETPLACE_MANIFEST" >/dev/null
}

marketplace_has_card() {
  jq -e \
    --arg name "$REPOSITORY" \
    --arg sha "$SOURCE_SHA" \
    --arg version "$RELEASE_VERSION" \
    --argjson release_id "$RELEASE_ID" \
    --arg release_tag "$RELEASE_TAG" \
    'any(.plugins[]; .name == $name and .source.sha == $sha and .metadata.version == $version and .metadata.releaseId == $release_id and .metadata.releaseTag == $release_tag and (.card | type == "object"))' \
    "$MARKETPLACE_MANIFEST" >/dev/null
}

main() {
  [[ $# -eq 0 ]] || fail "this helper accepts no arguments"
  require EVENT_ACTION
  require REPOSITORY
  require RELEASE_ID
  require RELEASE_TAG
  is_positive_uint "$RELEASE_ID" || fail "RELEASE_ID must be a positive canonical decimal integer"
  [[ "$REPOSITORY" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || fail "REPOSITORY has an invalid shape"

  load_current_release
  if [[ "$CURRENT_RELEASE_PRERELEASE" == true || "$CURRENT_RELEASE_DRAFT" == true ]]; then
    printf 'prerelease or draft release ignored\n'
    return
  fi
  [[ "$EVENT_ACTION" == published || "$EVENT_ACTION" == edited ]] || fail "unsupported release action: $EVENT_ACTION"

  require LATEST_STABLE_ID
  is_positive_uint "$LATEST_STABLE_ID" || fail "LATEST_STABLE_ID must be a positive canonical decimal integer"
  if [[ "$RELEASE_ID" != "$LATEST_STABLE_ID" ]]; then
    printf 'release %s is not latest stable %s; no-op\n' "$RELEASE_ID" "$LATEST_STABLE_ID"
    return
  fi

  RELEASE_VERSION="$(verify_release)"

  if ! marketplace_lists_release; then
    printf '::notice title=Not announced::hov-marketplace does not yet list %s %s at %s. Merge the repin PR, then edit the release to re-fire the announce.\n' \
      "$REPOSITORY" "$RELEASE_TAG" "$SOURCE_SHA"
    return
  fi

  if ! marketplace_has_card; then
    printf '::notice title=Not announced::%s has no card block in hov-marketplace. Add one (card: {rows, run}) in a marketplace PR, then edit the release to re-fire.\n' \
      "$REPOSITORY"
    return
  fi

  announce
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
