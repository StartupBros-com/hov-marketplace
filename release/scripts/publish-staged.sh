#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/scripts/plugin-tag.sh
source "$SCRIPT_DIR/plugin-tag.sh"
fail() { printf '::error::%s\n' "$*" >&2; exit 1; }
if [ "${1:-}" = --identity ]; then
  [ -n "${HOV_RELEASE_APP_ID:-}" ] && [ -n "${HOV_RELEASE_APP_PRIVATE_KEY:-}" ] \
    || fail "publish ${RELEASE_TAG:-<unset tag>} refuses without an identity: configure HOV_RELEASE_APP_ID and HOV_RELEASE_APP_PRIVATE_KEY"
  exit 0
fi
tag="${RELEASE_TAG:-}"
name="$(tag_plugin_name "$tag")" || fail "$tag is not a <name>--v<version> tag"
manifest="${MANIFEST:-.claude-plugin/marketplace.json}"
card="$(jq -ce --arg name "$name" '[.plugins[] | select(.name == $name)]
  | if length == 1 then .[0] else error("expected exactly one card") end' "$manifest")" \
  || fail "manifest $manifest does not contain exactly one card for $name"
[ "$(jq -r '.source.source' <<<"$card")" = git-subdir ] \
  || fail "card for $name is not git-subdir; a url card is published from its own repository"
pin="$(jq -r '.metadata.releaseTag // "<empty>"' <<<"$card")"
[ "$pin" = "$tag" ] || fail "card for $name pins $pin, not $tag; merge the repin first"
[ -n "$(jq -r '.metadata.releaseId // empty' <<<"$card")" ] \
  || fail "card for $name pins $tag but no releaseId; the reconciler has not recorded the draft"
export MANIFEST="$manifest" ONLY_PLUGIN="$name"
"${PUBLISHER:-$SCRIPT_DIR/repin-publish.sh}" || fail "publisher failed for $tag"
# The publisher skips with exit 0 when assets are incomplete or the live card moved;
# a dispatched publish that published nothing must not end green.
[ "${DRY_RUN:-0}" != 1 ] || exit 0
draft="$(gh release view "$tag" --json isDraft --jq .isDraft)" || fail "cannot read release $tag after the publisher ran"
[ "$draft" = false ] || fail "$tag is still a draft after the publisher ran; see its output above"
