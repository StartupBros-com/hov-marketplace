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
# Auth: a GitHub Actions OIDC token (Authorization: Bearer) minted by the
# workflow; the endpoint verifies the caller repo cryptographically. The
# legacy x-tool-release-announce-secret header is sent only when
# ANNOUNCE_SECRET is set (break-glass / transition).
#
# Soft exits (loud in the run UI, green in the checks list): marketplace not
# yet repinned to this release, or no card block registered — both resolve
# with a marketplace PR, then editing the release re-fires the announce.

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "$name is required"
}

is_uint() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]
}

notes_summary() {
  # Card-ready release bullets. Preference order: author-written "## Highlights"
  # section; GitHub's auto "What's Changed" bullets, cleaned; first paragraph.
  # Up to 3 bullets, each <=180 chars, total <=600.
  local notes bullets
  notes="$(printf '%s' "${RELEASE_NOTES:-}" | tr -d '\r')"
  [[ -n "$notes" ]] || return 0
  bullets="$(printf '%s\n' "$notes" | sed -n '/^##[[:space:]]*Highlights/,/^## /p' | grep -E '^[*•-][[:space:]]' || true)"
  if [[ -z "$bullets" ]]; then
    if printf '%s\n' "$notes" | grep -qE '^##[[:space:]]*What.?.?s Changed'; then
      bullets="$(printf '%s\n' "$notes" | sed -n '/^##[[:space:]]*What.\{0,2\}s Changed/,/^## /p' | grep -E '^\*[[:space:]]' || true)"
    elif [[ "$(printf '%s\n' "$notes" | grep -vE '^[[:space:]]*$' | head -n 1)" == \** ]]; then
      bullets="$(printf '%s\n' "$notes" | awk '/^[[:space:]]*$/{exit} /^\*[[:space:]]/{print}')"
    fi
  fi
  if [[ -n "$bullets" ]]; then
    # Character-safe slicing: cut -c is BYTES under GNU coreutils and can split
    # multibyte characters; python3 is guaranteed on the Actions runner.
    printf '%s\n' "$bullets" \
      | sed -E 's/^[*•-][[:space:]]+//; s/[[:space:]]+by @[A-Za-z0-9_[:punct:]]+ in http[^[:space:]]*[[:space:]]*$//; s/^(feat|fix|perf|chore|docs|refactor|test|ci|build)(\([^)]*\))?!?:[[:space:]]*//; s/[[:space:]]*\(v[0-9]+\.[0-9]+\.[0-9]+\)[[:space:]]*$//' \
      | python3 -c 'import sys
out = []
for line in sys.stdin.read().splitlines():
    line = line.strip()
    if line:
        out.append(line[:180])
    if len(out) == 3:
        break
print("\n".join(out)[:600])'
    return 0
  fi
  # Prose fallback: the drop card gets an excerpt instead of a what's-new list.
  # Warn loudly — a card that silently degrades reads as "this release had
  # nothing to say" (5 of 8 plugins' latest releases hit this path, 2026-08-11).
  printf '::warning title=No release highlights::%s %s has no "## Highlights" bullets; the drop card falls back to a prose excerpt. See docs/plugin-release-recipe.md.\n' \
    "${REPOSITORY:-plugin}" "${RELEASE_TAG:-release}" >&2
  printf '%s' "$notes" | awk 'BEGIN{RS=""} NR==1' | tr '\n' ' ' | cut -c1-600
}

announce() {
  require ANNOUNCE_URL
  local payload auth_args=()
  if [[ -n "${OIDC_TOKEN:-}" ]]; then
    auth_args+=(-H "authorization: Bearer $OIDC_TOKEN")
  fi
  if [[ -n "${ANNOUNCE_SECRET:-}" ]]; then
    auth_args+=(-H "x-tool-release-announce-secret: $ANNOUNCE_SECRET")
  fi
  [[ ${#auth_args[@]} -gt 0 ]] || fail "no announce credential: neither OIDC_TOKEN nor ANNOUNCE_SECRET is set"
  payload="$(jq -cn \
    --arg operation announce \
    --arg repository "$REPOSITORY" \
    --arg releaseId "$RELEASE_ID" \
    --arg tag "$RELEASE_TAG" \
    --arg releaseName "$RELEASE_NAME" \
    --arg releaseUrl "$RELEASE_URL" \
    --arg notesSummary "$(notes_summary)" \
    '{operation: $operation, repository: $repository, releaseId: $releaseId, tag: $tag, releaseName: $releaseName, releaseUrl: $releaseUrl} + (if $notesSummary == "" then {} else {notesSummary: $notesSummary} end)')"
  # Bounded retry honoring Retry-After. The service enforces a global 600s
  # verification gate per channel (429) and short-lived processing leases
  # (409, Retry-After: 2) — see hov-marketplace#56: on 2026-08-11 two plugin
  # releases 6 minutes apart turned a routine bump into three failed one-shot
  # attempts. 429/409/5xx/transport errors retry with the server's Retry-After
  # (clamped 5..600s, default attempt*60); anything else fails immediately.
  local attempt max_attempts=5 status retry_after body_file hdr_file
  body_file="$(mktemp)"
  hdr_file="$(mktemp)"
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    status="$(curl --silent --show-error \
      --output "$body_file" --dump-header "$hdr_file" \
      --write-out '%{http_code}' \
      -X POST \
      -H 'content-type: application/json' \
      "${auth_args[@]}" \
      --data "$payload" \
      "$ANNOUNCE_URL")" || status=000
    if [[ "$status" == 2* ]]; then
      cat "$body_file"
      return 0
    fi
    case "$status" in
      429 | 409 | 000 | 5*)
        if ((attempt < max_attempts)); then
          retry_after="$(awk 'tolower($1) == "retry-after:" {gsub(/\r/, ""); print $2; exit}' "$hdr_file")"
          [[ "$retry_after" =~ ^[0-9]+$ ]] || retry_after=$((attempt * 60))
          ((retry_after > 600)) && retry_after=600
          ((retry_after < 5)) && retry_after=5
          printf 'announce: HTTP %s (attempt %s/%s) — retrying in %ss\n' \
            "$status" "$attempt" "$max_attempts" "$retry_after" >&2
          sleep "$retry_after"
          continue
        fi
        ;;
    esac
    break
  done
  cat "$body_file" >&2
  fail "announce failed with HTTP $status after $attempt attempt(s)"
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
  [[ "$(git -C "$SOURCE_ROOT" rev-list -n 1 "$RELEASE_TAG")" == "$SOURCE_SHA" ]] || fail "release tag does not resolve to the exact release commit"
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
  jq -e --arg name "$REPOSITORY" \
    'any(.plugins[]; .name == $name and (.card | type == "object"))' \
    "$MARKETPLACE_MANIFEST" >/dev/null
}

main() {
  require EVENT_ACTION
  require REPOSITORY
  require RELEASE_ID
  require RELEASE_TAG
  require RELEASE_NAME
  require RELEASE_URL
  is_uint "$RELEASE_ID" || fail "RELEASE_ID must be an unsigned integer"
  [[ "$REPOSITORY" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || fail "REPOSITORY has an invalid shape"

  if [[ "${RELEASE_PRERELEASE:-false}" == true || "${RELEASE_DRAFT:-false}" == true ]]; then
    printf 'prerelease or draft release ignored\n'
    return
  fi
  [[ "$EVENT_ACTION" == published || "$EVENT_ACTION" == edited ]] || fail "unsupported release action: $EVENT_ACTION"

  require LATEST_STABLE_ID
  is_uint "$LATEST_STABLE_ID" || fail "LATEST_STABLE_ID must be an unsigned integer"
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
