#!/usr/bin/env bash
# Focused regressions for announce()'s bounded canonical Retry-After behavior.
# Stubs token mint, HTTP send, and sleep; no network or real waiting occurs.
# shellcheck disable=SC2030,SC2031,SC2317,SC2329
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$HERE")"
PASS=0
FAIL=0

setup() {
  WORK="$(mktemp -d)"
  STUB_SCENARIO="$WORK/scenario"
  STUB_CALLS="$WORK/calls"
  STUB_SLEEPS="$WORK/sleeps"
  STUB_MINTS="$WORK/mints"
  STUB_AUDIENCES="$WORK/audiences"
  STUB_BODY="$WORK/body"
  STUB_POST_TOKENS="$WORK/post-tokens"
  : >"$STUB_CALLS"
  : >"$STUB_SLEEPS"
  : >"$STUB_MINTS"
  : >"$STUB_AUDIENCES"
  : >"$STUB_BODY"
  : >"$STUB_POST_TOKENS"

  export REPOSITORY="stub-repo" RELEASE_ID="1"
  export CURRENT_RELEASE_NOTES=""
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/tool-drop-announce.sh"

  mint_oidc_token() {
    printf '%s\n' "$1" >>"$STUB_AUDIENCES"
    printf 'mint\n' >>"$STUB_MINTS"
    printf 'stub-token-%s\n' "$(wc -l <"$STUB_MINTS")"
  }

  send_request() {
    local request_body="$1" oidc_token="$3" response_body="$4" response_headers="$5" status_name="$6"
    local line_no line status body retry_after
    printf '%s\n' "$oidc_token" >>"$STUB_POST_TOKENS"
    printf '%s' "$request_body" >"$STUB_BODY"
    printf 'post\n' >>"$STUB_CALLS"
    line_no="$(wc -l <"$STUB_CALLS")"
    line="$(sed -n "${line_no}p" "$STUB_SCENARIO")"
    status="${line%% *}"
    line="${line#* }"
    body="${line%% *}"
    retry_after="${line#* }"
    printf '%s' "$body" >"$response_body"
    printf 'HTTP/1.1 %s Fixture\r\n' "$status" >"$response_headers"
    if [[ "$retry_after" != "$line" && -n "$retry_after" ]]; then
      printf 'Retry-After: %s\r\n' "$retry_after" >>"$response_headers"
    fi
    printf '\r\n' >>"$response_headers"
    printf -v "$status_name" '%s' "$status"
  }

  sleep() {
    printf '%s\n' "$1" >>"$STUB_SLEEPS"
  }
}

report() {
  if [[ "$2" == 0 ]]; then
    printf 'ok - %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf 'not ok - %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

(
  setup
  printf '200 posted\n' >"$STUB_SCENARIO"
  out="$(announce)" || exit 1
  [[ "$out" == *posted ]] || exit 1
  [[ "$(wc -l <"$STUB_CALLS")" == 1 ]] || exit 1
  [[ "$(wc -l <"$STUB_MINTS")" == 1 ]] || exit 1
  [[ ! -s "$STUB_SLEEPS" ]] || exit 1
)
report "200 succeeds on the first freshly minted token" $?

(
  setup
  printf '429 limited 3\n200 posted\n' >"$STUB_SCENARIO"
  out="$(announce)" || exit 1
  [[ "$out" == *posted ]] || exit 1
  [[ "$(wc -l <"$STUB_CALLS")" == 2 ]] || exit 1
  [[ "$(wc -l <"$STUB_MINTS")" == 2 ]] || exit 1
  jitter="$(retry_jitter_seconds "$REPOSITORY" "$RELEASE_ID" 1)"
  [[ "$(<"$STUB_SLEEPS")" == "$((3 + RETRY_LEASE_EXPIRY_CUSHION_SECONDS + jitter))" ]] || exit 1
)
report "canonical 429 retries with cushion and deterministic jitter" $?

(
  setup
  printf '400 bad\n200 posted\n' >"$STUB_SCENARIO"
  if (announce) >/dev/null 2>&1; then exit 1; fi
  [[ "$(wc -l <"$STUB_CALLS")" == 1 ]] || exit 1
  [[ "$(wc -l <"$STUB_MINTS")" == 1 ]] || exit 1
  [[ ! -s "$STUB_SLEEPS" ]] || exit 1
)
report "400 fails immediately without retry (planted negative)" $?

(
  setup
  for _ in $(seq 1 "$ANNOUNCE_MAX_ATTEMPTS"); do
    printf '409 busy 2\n'
  done >"$STUB_SCENARIO"
  if (announce) >/dev/null 2>&1; then exit 1; fi
  [[ "$(wc -l <"$STUB_CALLS")" == "$ANNOUNCE_MAX_ATTEMPTS" ]] || exit 1
  [[ "$(wc -l <"$STUB_MINTS")" == "$ANNOUNCE_MAX_ATTEMPTS" ]] || exit 1
  [[ "$(wc -l <"$STUB_SLEEPS")" == "$((ANNOUNCE_MAX_ATTEMPTS - 1))" ]] || exit 1
)
report "persistent canonical 409 exhausts eight attempts without a ninth" $?

(
  setup
  source_root="$WORK/source"
  manifest="$WORK/manifest.json"
  mkdir -p "$source_root/.claude-plugin"
  printf '1.2.3\n' >"$source_root/VERSION"
  printf '{"version":"1.2.3"}\n' >"$source_root/.claude-plugin/plugin.json"
  git -C "$source_root" init -q
  git -C "$source_root" config user.name Fixture
  git -C "$source_root" config user.email fixture@example.com
  git -C "$source_root" add VERSION .claude-plugin/plugin.json
  git -C "$source_root" commit -qm fixture
  git -C "$source_root" tag v1.2.3
  source_sha="$(git -C "$source_root" rev-parse HEAD)"
  jq -n --arg sha "$source_sha" \
    '{plugins:[{name:"stub-repo",source:{sha:$sha},metadata:{version:"1.2.3",releaseId:1,releaseTag:"v1.2.3"},card:{rows:["one","two","three"],run:"Run"}}]}' \
    >"$manifest"
  export EVENT_ACTION=published RELEASE_TAG=v1.2.3 LATEST_STABLE_ID=1
  export SOURCE_ROOT="$source_root" SOURCE_SHA="$source_sha" MARKETPLACE_MANIFEST="$manifest"
  export ANNOUNCE_URL=https://attacker.invalid OIDC_TOKEN=caller-token
  export RELEASE_NAME='Caller title' RELEASE_URL=https://attacker.invalid/release
  printf '200 posted\n' >"$STUB_SCENARIO"
  out="$(main)" || exit 1
  [[ "$out" == *posted ]] || exit 1
  [[ "$(<"$STUB_AUDIENCES")" == "$LEGACY_OIDC_AUDIENCE" ]] || exit 1
  [[ "$(<"$STUB_POST_TOKENS")" == stub-token-1 ]] || exit 1
  [[ "$(<"$STUB_BODY")" == '{"operation":"announce","repository":"stub-repo","releaseId":"1","tag":"v1.2.3","releaseName":"stub-repo v1.2.3","releaseUrl":"https://github.com/StartupBros-com/stub-repo/releases/tag/v1.2.3"}' ]] || exit 1
  [[ "$(wc -l <"$STUB_MINTS")" == 1 ]] || exit 1
)
report "legacy workflow main path uses canonical fields and a fresh generic-audience token" $?

(
  setup
  export EVENT_ACTION=published RELEASE_TAG=v1.2.3 LATEST_STABLE_ID=1
  export SOURCE_ROOT="$WORK/source" SOURCE_SHA=fixture MARKETPLACE_MANIFEST="$WORK/manifest.json"
  export OIDC_TOKEN=caller-token ANNOUNCE_SECRET=forbidden
  if (main) >/dev/null 2>&1; then exit 1; fi
  [[ ! -s "$STUB_MINTS" && ! -s "$STUB_CALLS" ]] || exit 1
)
report "legacy workflow rejects secret authentication before mint or send" $?

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
