#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT/scripts/validate-marketplace.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REMOTE_ROOT="$TMP/remotes"
WORK="$TMP/work"
mkdir -p "$REMOTE_ROOT/StartupBros-com" "$WORK/.claude-plugin"

pass_count=0
fail_count=0

expect_pass() {
  local label="$1"
  shift
  if "$@" >"$TMP/output" 2>&1; then
    printf 'ok - %s\n' "$label"
    pass_count=$((pass_count + 1))
  else
    printf 'not ok - %s\n' "$label" >&2
    command cat "$TMP/output" >&2
    exit 1
  fi
}

expect_fail() {
  local label="$1"
  shift
  if "$@" >"$TMP/output" 2>&1; then
    printf 'not ok - %s unexpectedly passed\n' "$label" >&2
    exit 1
  else
    printf 'ok - %s\n' "$label"
    fail_count=$((fail_count + 1))
  fi
}

make_plugin() {
  local name="$1" version="$2" tag="$3"
  local repo="$TMP/$name"
  git init -q "$repo"
  git -C "$repo" config user.name Fixture
  git -C "$repo" config user.email fixture@example.com
  mkdir -p "$repo/.claude-plugin" "$repo/skills/$name" "$repo/.github/workflows"
  jq -n --arg name "$name" --arg version "$version" '{name: $name, version: $version}' >"$repo/.claude-plugin/plugin.json"
  printf '%s\n' "$version" >"$repo/VERSION"
  printf '# fixture\n' >"$repo/skills/$name/SKILL.md"
  cat >"$repo/.github/workflows/release-train.yml" <<'EOF'
name: Release train
on:
  release:
    types: [published, edited]
permissions:
  contents: read
  id-token: write
jobs:
  announce:
    uses: StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@c981b872ebf650805200ad72c8b7142232f8b3f6
EOF
  git -C "$repo" add .claude-plugin/plugin.json "skills/$name/SKILL.md" VERSION .github/workflows/release-train.yml
  git -C "$repo" commit -qm fixture
  git -C "$repo" branch -M main
  git -C "$repo" tag "$tag"
  git clone -q --bare "$repo" "$REMOTE_ROOT/StartupBros-com/$name.git"
  git -C "$repo" rev-parse HEAD
}

TOKEN_SHA="$(make_plugin token-eater 1.2.3 v1.2.3)"
PRO_SHA="$(make_plugin pro-gate 2.0.0 v2.0.0)"

write_manifest() {
  local token_sha="$1" pro_sha="$2" token_id="$3" token_name="${4:-token-eater}" token_version="${5:-1.2.3}" token_tag="${6:-v1.2.3}"
  jq -n \
    --arg token_name "$token_name" --arg token_sha "$token_sha" --arg token_version "$token_version" --arg token_tag "$token_tag" --argjson token_id "$token_id" \
    --arg pro_sha "$pro_sha" \
    '{
      name: "hov",
      owner: {name: "House of Vibe", url: "https://houseofvibe.ai"},
      metadata: {description: "Tools for builders.", version: "1.0.0"},
      plugins: [
        {name: $token_name, source: {source: "url", url: "https://github.com/StartupBros-com/token-eater.git", sha: $token_sha}, description: "Token eater.", metadata: {version: $token_version, releaseId: $token_id, releaseTag: $token_tag}},
        {name: "pro-gate", source: {source: "url", url: "https://github.com/StartupBros-com/pro-gate.git", sha: $pro_sha}, description: "Pro gate.", metadata: {version: "2.0.0", releaseId: 20, releaseTag: "v2.0.0"}}
      ]
    }' >"$WORK/.claude-plugin/marketplace.json"
}

validate() {
  (cd "$WORK" && MARKETPLACE_TEST_REMOTE_ROOT="$REMOTE_ROOT" ALLOW_LOCAL_FILE_REMOTES=1 "$VALIDATOR" "$@")
}

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
expect_pass "valid syntax" validate syntax
expect_pass "valid full fixture and U7 expectations" env EXPECTED_PLUGIN_NAME=token-eater EXPECTED_PLUGIN_VERSION=1.2.3 EXPECTED_RELEASE_ID=10 EXPECTED_RELEASE_TAG=v1.2.3 EXPECTED_SHA="$TOKEN_SHA" EXPECTED_PAYLOAD_PATHS=.claude-plugin/plugin.json,skills/token-eater/SKILL.md bash -c 'cd "$1" && MARKETPLACE_TEST_REMOTE_ROOT="$2" ALLOW_LOCAL_FILE_REMOTES=1 "$3" full' _ "$WORK" "$REMOTE_ROOT" "$VALIDATOR"

# Announcement-contract failures are pinned-tree defects. Omit release metadata
# on these fixtures so the failure is the contract itself, never tag resolution.
write_unreleased_manifest() {
  local sha="$1"
  write_manifest "$sha" "$PRO_SHA" 10
  jq 'del(.plugins[0].metadata)' "$WORK/.claude-plugin/marketplace.json" >"$TMP/unreleased.json"
  mv "$TMP/unreleased.json" "$WORK/.claude-plugin/marketplace.json"
}
publish_fixture_commit() {
  git -C "$TMP/token-eater" add -A
  git -C "$TMP/token-eater" commit -qm "$1"
  git -C "$TMP/token-eater" push -q "$REMOTE_ROOT/StartupBros-com/token-eater.git" HEAD:main
  git -C "$TMP/token-eater" rev-parse HEAD
}

git -C "$TMP/token-eater" rm -q VERSION
MISSING_VERSION_SHA="$(publish_fixture_commit 'missing version')"
write_unreleased_manifest "$MISSING_VERSION_SHA"
expect_fail "pinned plugin without VERSION rejected before release" validate full

printf '9.9.9\n' >"$TMP/token-eater/VERSION"
MISMATCH_VERSION_SHA="$(publish_fixture_commit 'mismatched version')"
write_unreleased_manifest "$MISMATCH_VERSION_SHA"
expect_fail "VERSION must match pinned plugin manifest" validate full

printf '1.2.3\n' >"$TMP/token-eater/VERSION"
sed -i 's/c981b872ebf650805200ad72c8b7142232f8b3f6/0000000000000000000000000000000000000000/' "$TMP/token-eater/.github/workflows/release-train.yml"
BAD_PIN_SHA="$(publish_fixture_commit 'wrong announce pin')"
write_unreleased_manifest "$BAD_PIN_SHA"
expect_fail "release train must pin blessed announce workflow" validate full

sed -i 's/0000000000000000000000000000000000000000/c981b872ebf650805200ad72c8b7142232f8b3f6/; /id-token: write/d' "$TMP/token-eater/.github/workflows/release-train.yml"
NO_OIDC_SHA="$(publish_fixture_commit 'missing oidc permission')"
write_unreleased_manifest "$NO_OIDC_SHA"
expect_fail "release train requires OIDC permission" validate full

sed -i '/contents: read/a\  id-token: write' "$TMP/token-eater/.github/workflows/release-train.yml"
printf '\n# TOOL_RELEASE_ANNOUNCE_SECRET must never return\n' >>"$TMP/token-eater/.github/workflows/release-train.yml"
STATIC_SECRET_SHA="$(publish_fixture_commit 'static announce secret')"
write_unreleased_manifest "$STATIC_SECRET_SHA"
expect_fail "static announce secret is forbidden" validate full

printf '{broken\n' >"$WORK/.claude-plugin/marketplace.json"
expect_fail "malformed JSON" validate syntax

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
expect_pass "private sources stay syntax-only and network-free" env MARKETPLACE_MANIFEST="$WORK/.claude-plugin/marketplace.json" "$VALIDATOR" syntax
expect_fail "local file remotes require explicit override" env MARKETPLACE_MANIFEST="$WORK/.claude-plugin/marketplace.json" MARKETPLACE_TEST_REMOTE_ROOT="$REMOTE_ROOT" "$VALIDATOR" full

BAD_SHA="0000000000000000000000000000000000000000"
write_manifest "$BAD_SHA" "$PRO_SHA" 10
expect_fail "unreachable SHA" validate full

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
(cd "$WORK" && git init -q && git config user.name Fixture && git config user.email fixture@example.com && git add .claude-plugin/marketplace.json && git commit -qm base)
write_manifest "$TOKEN_SHA" "$PRO_SHA" 9
expect_fail "release metadata rollback" env BASE_REF=HEAD MARKETPLACE_MANIFEST=.claude-plugin/marketplace.json MARKETPLACE_TEST_REMOTE_ROOT="$REMOTE_ROOT" ALLOW_LOCAL_FILE_REMOTES=1 bash -c 'cd "$1" && "$2" syntax' _ "$WORK" "$VALIDATOR"

write_manifest "$TOKEN_SHA" "$PRO_SHA" 11 token-eater 1.2.2 v1.2.2
expect_fail "newer release id cannot downgrade semver" env BASE_REF=HEAD MARKETPLACE_MANIFEST=.claude-plugin/marketplace.json bash -c 'cd "$1" && "$2" syntax' _ "$WORK" "$VALIDATOR"

write_manifest "$TOKEN_SHA" "$PRO_SHA" 11 token-eater 1.2.3 v1.2.3
expect_fail "newer release id requires semver increase" env BASE_REF=HEAD MARKETPLACE_MANIFEST=.claude-plugin/marketplace.json bash -c 'cd "$1" && "$2" syntax' _ "$WORK" "$VALIDATOR"

write_manifest "$PRO_SHA" "$PRO_SHA" 10
expect_fail "equal release id cannot change source" env BASE_REF=HEAD MARKETPLACE_MANIFEST=.claude-plugin/marketplace.json bash -c 'cd "$1" && "$2" syntax' _ "$WORK" "$VALIDATOR"

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
jq '(.plugins[] | select(.name == "token-eater") | .source.url) = "https://github.com/attacker/token-eater.git"' "$WORK/.claude-plugin/marketplace.json" > "$TMP/wrong-source.json"
mv "$TMP/wrong-source.json" "$WORK/.claude-plugin/marketplace.json"
expect_fail "approved plugin cannot change repository owner" validate syntax

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10 wrong-name
expect_fail "pinned manifest name mismatch" validate full

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10 token-eater 1.2.4 v1.2.4
expect_fail "pinned manifest version mismatch" validate full

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10 token-eater 1.2.3 v9.9.9
expect_fail "release tag mismatch" validate syntax

write_manifest "${TOKEN_SHA^^}" "$PRO_SHA" 10
expect_fail "uppercase SHA rejected" validate syntax

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
jq '.plugins += [.plugins[0]]' "$WORK/.claude-plugin/marketplace.json" >"$TMP/duplicate.json"
mv "$TMP/duplicate.json" "$WORK/.claude-plugin/marketplace.json"
expect_fail "duplicate plugin names" validate syntax

# --- card block (Tool Drop copy lives in the manifest; shape-gated here) ---

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
jq '.plugins[0].card = {rows: ["one", "two", "three"], run: "Then run it"}' "$WORK/.claude-plugin/marketplace.json" >"$TMP/card-ok.json"
mv "$TMP/card-ok.json" "$WORK/.claude-plugin/marketplace.json"
expect_pass "valid card block accepted" validate syntax

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
jq '.plugins[0].card = {rows: ["one", "two"], run: "Then run it"}' "$WORK/.claude-plugin/marketplace.json" >"$TMP/card-tworows.json"
mv "$TMP/card-tworows.json" "$WORK/.claude-plugin/marketplace.json"
expect_fail "card must carry exactly three rows" validate syntax

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
jq --arg long "$(printf 'x%.0s' $(seq 1 181))" '.plugins[0].card = {rows: [$long, "two", "three"], run: "Then run it"}' "$WORK/.claude-plugin/marketplace.json" >"$TMP/card-longrow.json"
mv "$TMP/card-longrow.json" "$WORK/.claude-plugin/marketplace.json"
expect_fail "card row over 180 chars rejected" validate syntax

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
jq '.plugins[0].card = {rows: ["one", "two", "three"], run: "Then run it", banner: "nope"}' "$WORK/.claude-plugin/marketplace.json" >"$TMP/card-unknown.json"
mv "$TMP/card-unknown.json" "$WORK/.claude-plugin/marketplace.json"
expect_fail "unknown card key rejected" validate syntax

write_manifest "$TOKEN_SHA" "$PRO_SHA" 10
jq '.plugins[0].card = {rows: ["one", "two", "three"]}' "$WORK/.claude-plugin/marketplace.json" >"$TMP/card-norun.json"
mv "$TMP/card-norun.json" "$WORK/.claude-plugin/marketplace.json"
expect_fail "card without run line rejected" validate syntax

printf '%d passing cases, %d expected failures\n' "$pass_count" "$fail_count"
