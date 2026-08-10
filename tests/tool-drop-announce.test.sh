#!/usr/bin/env bash
# Static mutation needles intentionally quote shell and Actions expressions.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/hov-tool-drop-announce.yml"
HELPER="$ROOT/scripts/tool-drop-announce.sh"
FIXED_ENDPOINT='https://members.startupbros.com/api/internal/ops/tool-releases'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass_count=0

die() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
  pass_count=$((pass_count + 1))
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

for command_name in git jq python3 sha256sum yq; do
  require_command "$command_name"
done

check_contract() {
  local workflow="$1" helper="$2"
  local input_count secret_count fixed_count
  local release_index ancestry_index trusted_index manifest_index announce_index
  local release_ref trusted_repository trusted_ref trusted_path trusted_credentials
  local manifest_repository manifest_ref manifest_path manifest_credentials
  local ancestry_run expected_ancestry announce_run expected_announce manifest_env
  local send_block header_count mask_line send_line

  input_count="$(yq -r '.on.workflow_call.inputs // {} | length' "$workflow")" || return 1
  secret_count="$(yq -r '.on.workflow_call.secrets // {} | length' "$workflow")" || return 1
  [[ "$input_count" == 0 && "$secret_count" == 0 ]] || return 1
  ! grep -Eq 'announce-url|ANNOUNCE_URL|ANNOUNCE_SECRET|OIDC_TOKEN|x-tool-release-announce-secret' "$workflow" "$helper" || return 1

  fixed_count="$({ grep -Fo "$FIXED_ENDPOINT" "$helper" || true; } | wc -l)"
  [[ "$fixed_count" == 1 ]] || return 1
  grep -Fxq "readonly TOOL_RELEASES_ENDPOINT='$FIXED_ENDPOINT'" "$helper" || return 1
  ! grep -Fq "$FIXED_ENDPOINT" "$workflow" || return 1

  release_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Check out release commit") | .key' "$workflow")" || return 1
  ancestry_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Require release commit on default branch") | .key' "$workflow")" || return 1
  trusted_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Check out trusted workflow helper") | .key' "$workflow")" || return 1
  manifest_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Check out current marketplace manifest") | .key' "$workflow")" || return 1
  announce_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Announce release") | .key' "$workflow")" || return 1
  [[ "$release_index" =~ ^[0-9]+$ && "$ancestry_index" =~ ^[0-9]+$ && "$trusted_index" =~ ^[0-9]+$ && "$manifest_index" =~ ^[0-9]+$ && "$announce_index" =~ ^[0-9]+$ ]] || return 1
  ((release_index + 1 == ancestry_index && ancestry_index < trusted_index && trusted_index < manifest_index && manifest_index < announce_index)) || return 1

  release_ref="$(yq -r '.jobs.announce.steps[] | select(.name == "Check out release commit") | .with.ref' "$workflow")" || return 1
  [[ "$release_ref" == 'refs/tags/${{ github.event.release.tag_name }}' ]] || return 1
  ancestry_run="$(yq -r '.jobs.announce.steps[] | select(.name == "Require release commit on default branch") | .run' "$workflow")" || return 1
  expected_ancestry=$'git fetch origin "$DEFAULT_BRANCH"\nrelease_sha="$(git rev-list -n 1 "refs/tags/$RELEASE_TAG")"\ngit merge-base --is-ancestor "$release_sha" "origin/$DEFAULT_BRANCH"'
  [[ "$ancestry_run" == "$expected_ancestry" ]] || return 1

  trusted_repository="$(yq -r '.jobs.announce.steps[] | select(.name == "Check out trusted workflow helper") | .with.repository' "$workflow")" || return 1
  trusted_ref="$(yq -r '.jobs.announce.steps[] | select(.name == "Check out trusted workflow helper") | .with.ref' "$workflow")" || return 1
  trusted_path="$(yq -r '.jobs.announce.steps[] | select(.name == "Check out trusted workflow helper") | .with.path' "$workflow")" || return 1
  trusted_credentials="$(yq -r '.jobs.announce.steps[] | select(.name == "Check out trusted workflow helper") | .with.persist-credentials' "$workflow")" || return 1
  [[ "$trusted_repository" == '${{ job.workflow_repository }}' ]] || return 1
  [[ "$trusted_ref" == '${{ job.workflow_sha }}' ]] || return 1
  [[ -n "$trusted_path" && "$trusted_credentials" == false ]] || return 1

  manifest_repository="$(yq -r '.jobs.announce.steps[] | select(.name == "Check out current marketplace manifest") | .with.repository' "$workflow")" || return 1
  manifest_ref="$(yq -r '.jobs.announce.steps[] | select(.name == "Check out current marketplace manifest") | .with.ref' "$workflow")" || return 1
  manifest_path="$(yq -r '.jobs.announce.steps[] | select(.name == "Check out current marketplace manifest") | .with.path' "$workflow")" || return 1
  manifest_credentials="$(yq -r '.jobs.announce.steps[] | select(.name == "Check out current marketplace manifest") | .with.persist-credentials' "$workflow")" || return 1
  [[ "$manifest_repository" == StartupBros-com/hov-marketplace && "$manifest_ref" == main ]] || return 1
  [[ -n "$manifest_path" && "$manifest_path" != "$trusted_path" && "$manifest_credentials" == false ]] || return 1

  announce_run="$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .run' "$workflow")" || return 1
  manifest_env="$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env.MARKETPLACE_MANIFEST' "$workflow")" || return 1
  expected_announce=$'source_sha="$(git rev-list -n 1 "refs/tags/$RELEASE_TAG")"\nexport SOURCE_SHA="$source_sha"\n'
  expected_announce+="./$trusted_path/scripts/tool-drop-announce.sh"
  [[ "$announce_run" == "$expected_announce" ]] || return 1
  [[ "$manifest_env" == *"/$manifest_path/.claude-plugin/marketplace.json" ]] || return 1
  ! grep -Fq 'ACTIONS_ID_TOKEN_REQUEST_URL' "$workflow" || return 1

  grep -Fq 'readonly request_body' "$helper" || return 1
  grep -Fq 'local -r request_body="$1" expected_sha="$2" oidc_token="$3"' "$helper" || return 1
  grep -Fq 'request_sha="$(sha256_bytes "$request_body")"' "$helper" || return 1
  grep -Fq 'audience="${TOOL_RELEASES_ENDPOINT}#sha256=$request_sha"' "$helper" || return 1
  grep -Fq -- '--data-urlencode "audience=$audience"' "$helper" || return 1
  grep -Fq 'send_request "$request_body" "$request_sha" "$oidc_token"' "$helper" || return 1
  grep -Fq 'actual_sha="$(sha256_bytes "$request_body")"' "$helper" || return 1
  grep -Fq '[[ "$actual_sha" == "$expected_sha" ]] || fail "request body changed after OIDC mint"' "$helper" || return 1
  grep -Fq -- '--data-binary "$request_body"' "$helper" || return 1
  grep -Fq '"$TOOL_RELEASES_ENDPOINT"' "$helper" || return 1
  grep -Fq '[[ $# -eq 0 ]] || fail "this helper accepts no arguments"' "$helper" || return 1
  ! grep -Fq -- '--location' "$helper" || return 1

  send_block="$(sed -n '/^send_request() {/,/^}/p' "$helper")"
  header_count="$(printf '%s\n' "$send_block" | grep -cE '^[[:space:]]+-H ' || true)"
  [[ "$header_count" == 2 ]] || return 1
  grep -Fq -- "-H 'content-type: application/json'" <<<"$send_block" || return 1
  grep -Fq -- '-H "authorization: Bearer $oidc_token"' <<<"$send_block" || return 1

  mask_line="$({ grep -nF "printf '::add-mask::%s\\n' \"\$oidc_token\"" "$helper" || true; } | cut -d: -f1)"
  send_line="$({ grep -nF 'send_request "$request_body" "$request_sha" "$oidc_token"' "$helper" || true; } | cut -d: -f1)"
  [[ "$mask_line" =~ ^[0-9]+$ && "$send_line" =~ ^[0-9]+$ ]] || return 1
  ((mask_line < send_line)) || return 1
}

replace_once() {
  local source="$1" destination="$2" old="$3" new="$4"
  python3 - "$source" "$destination" "$old" "$new" <<'PY'
from pathlib import Path
import sys

source, destination, old, new = sys.argv[1:]
text = Path(source).read_text()
count = text.count(old)
if count != 1:
    raise SystemExit(f"expected one mutation target, found {count}: {old!r}")
Path(destination).write_text(text.replace(old, new, 1))
PY
}

expect_contract_reject() {
  local label="$1" workflow="$2" helper="$3"
  if check_contract "$workflow" "$helper" >/dev/null 2>&1; then
    die "$label mutation escaped the static contract"
  fi
  pass "$label mutation rejected"
}

check_contract "$WORKFLOW" "$HELPER" || die "trusted workflow/helper static contract"
pass "trusted workflow/helper static contract"

mutant="$TMP/workflow-input.yml"
replace_once "$WORKFLOW" "$mutant" $'  workflow_call:\n' $'  workflow_call:\n    inputs:\n      announce-url:\n        type: string\n        required: false\n'
expect_contract_reject "caller URL input" "$mutant" "$HELPER"

mutant="$TMP/workflow-mutable-ref.yml"
replace_once "$WORKFLOW" "$mutant" 'ref: ${{ job.workflow_sha }}' 'ref: main'
expect_contract_reject "mutable helper checkout" "$mutant" "$HELPER"

mutant="$TMP/workflow-ancestry-bypass.yml"
replace_once "$WORKFLOW" "$mutant" 'git merge-base --is-ancestor "$release_sha" "origin/$DEFAULT_BRANCH"' 'true'
expect_contract_reject "release ancestry bypass" "$mutant" "$HELPER"

mutant="$TMP/workflow-mutable-helper.yml"
replace_once "$WORKFLOW" "$mutant" './trusted-workflow/scripts/tool-drop-announce.sh' './marketplace-data/scripts/tool-drop-announce.sh'
expect_contract_reject "mutable-main helper execution" "$mutant" "$HELPER"

mutant="$TMP/helper-caller-url.sh"
replace_once "$HELPER" "$mutant" "readonly TOOL_RELEASES_ENDPOINT='$FIXED_ENDPOINT'" 'readonly TOOL_RELEASES_ENDPOINT="${ANNOUNCE_URL:?}"'
expect_contract_reject "caller-controlled helper endpoint" "$WORKFLOW" "$mutant"

mutant="$TMP/helper-secret-header.sh"
replace_once "$HELPER" "$mutant" "-H 'content-type: application/json'" "-H 'x-tool-release-announce-secret: fixture'"
expect_contract_reject "secret header" "$WORKFLOW" "$mutant"

mutant="$TMP/helper-generic-audience.sh"
replace_once "$HELPER" "$mutant" 'audience="${TOOL_RELEASES_ENDPOINT}#sha256=$request_sha"' 'audience="$TOOL_RELEASES_ENDPOINT"'
expect_contract_reject "generic OIDC audience" "$WORKFLOW" "$mutant"

mutant="$TMP/helper-mutable-send-body.sh"
replace_once "$HELPER" "$mutant" \
  'local -r request_body="$1" expected_sha="$2" oidc_token="$3"' \
  'local request_body="$1" expected_sha="$2" oidc_token="$3"'
expect_contract_reject "mutable send body" "$WORKFLOW" "$mutant"

mutant="$TMP/helper-post-check-body.sh"
replace_once "$HELPER" "$mutant" '--data-binary "$request_body"' '--data-binary "${request_body}x"'
expect_contract_reject "body alteration after digest guard" "$WORKFLOW" "$mutant"

mutant="$TMP/helper-mask-order.sh"
mask_statement="  printf '::add-mask::%s\\n' \"\$oidc_token\""
send_statement='  send_request "$request_body" "$request_sha" "$oidc_token"'
replace_once "$HELPER" "$mutant" \
  "$mask_statement"$'\n'"$send_statement" \
  "$send_statement"$'\n'"$mask_statement"
expect_contract_reject "token mask ordering" "$WORKFLOW" "$mutant"

FIXTURE_REPOSITORY='fixture-tool'
FIXTURE_VERSION='1.2.3'
FIXTURE_TAG="v$FIXTURE_VERSION"
FIXTURE_RELEASE_ID='42'
SOURCE_ROOT="$TMP/source"
MANIFEST="$TMP/marketplace.json"
FAKE_BIN="$TMP/bin"
CALLS_FILE="$TMP/curl-calls"
BODY_FILE="$TMP/request-body"
HEADERS_FILE="$TMP/request-headers"
URL_FILE="$TMP/request-url"
AUDIENCE_FILE="$TMP/oidc-audience"
OIDC_URL='https://token.actions.test/oidc?api-version=fixture'
ORIGINAL_PATH="$PATH"
mkdir -p "$SOURCE_ROOT/.claude-plugin" "$FAKE_BIN"

printf '%s\n' "$FIXTURE_VERSION" >"$SOURCE_ROOT/VERSION"
jq -n --arg name "$FIXTURE_REPOSITORY" --arg version "$FIXTURE_VERSION" \
  '{name: $name, version: $version}' >"$SOURCE_ROOT/.claude-plugin/plugin.json"
git -C "$SOURCE_ROOT" init -q
git -C "$SOURCE_ROOT" config user.name Fixture
git -C "$SOURCE_ROOT" config user.email fixture@example.com
git -C "$SOURCE_ROOT" add VERSION .claude-plugin/plugin.json
git -C "$SOURCE_ROOT" commit -qm fixture
git -C "$SOURCE_ROOT" tag "$FIXTURE_TAG"
SOURCE_SHA="$(git -C "$SOURCE_ROOT" rev-list -n 1 "$FIXTURE_TAG")"

jq -n \
  --arg name "$FIXTURE_REPOSITORY" \
  --arg sha "$SOURCE_SHA" \
  --arg version "$FIXTURE_VERSION" \
  --arg tag "$FIXTURE_TAG" \
  --argjson release_id "$FIXTURE_RELEASE_ID" \
  '{plugins: [{name: $name, source: {sha: $sha}, metadata: {version: $version, releaseId: $release_id, releaseTag: $tag}, card: {rows: ["one", "two", "three"], run: "Run it"}}]}' \
  >"$MANIFEST"

cat >"$FAKE_BIN/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

headers=()
request_body=''
audience_option=''
method=''
url=''
is_get=false

while (($# > 0)); do
  case "$1" in
    -H|--header)
      headers+=("$2")
      shift 2
      ;;
    --data-binary)
      request_body="$2"
      shift 2
      ;;
    --data-urlencode)
      audience_option="$2"
      shift 2
      ;;
    --request|-X)
      method="$2"
      shift 2
      ;;
    --get)
      is_get=true
      shift
      ;;
    --fail-with-body|--silent|--show-error)
      shift
      ;;
    -*)
      printf 'unexpected curl option: %s\n' "$1" >&2
      exit 90
      ;;
    *)
      [[ -z "$url" ]] || { printf 'multiple curl URLs\n' >&2; exit 91; }
      url="$1"
      shift
      ;;
  esac
done

if [[ "$url" == "$ACTIONS_ID_TOKEN_REQUEST_URL" ]]; then
  printf 'oidc\n' >>"$FAKE_CURL_CALLS_FILE"
  [[ "$is_get" == true && -z "$method" && -z "$request_body" ]] || exit 92
  [[ ${#headers[@]} -eq 1 && "${headers[0]}" == "authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" ]] || exit 93
  [[ "$audience_option" == audience=* ]] || exit 94
  audience="${audience_option#audience=}"
  [[ "$audience" == "$EXPECTED_ENDPOINT#sha256="* ]] || exit 95
  digest="${audience##*#sha256=}"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || exit 96
  printf '%s' "$audience" >"$FAKE_CURL_AUDIENCE_FILE"
  printf '{"value":"fixture-token-%s"}' "$digest"
  exit 0
fi

if [[ "$url" == "$EXPECTED_ENDPOINT" ]]; then
  printf 'post\n' >>"$FAKE_CURL_CALLS_FILE"
  [[ "$is_get" == false && "$method" == POST && -z "$audience_option" ]] || exit 97
  [[ ${#headers[@]} -eq 2 ]] || exit 98
  [[ "${headers[0]}" == 'content-type: application/json' ]] || exit 99
  posted_sha="$(printf '%s' "$request_body" | sha256sum)"
  posted_sha="${posted_sha%% *}"
  [[ "${headers[1]}" == "authorization: Bearer fixture-token-$posted_sha" ]] || exit 100
  printf '%s' "$request_body" >"$FAKE_CURL_BODY_FILE"
  printf '%s\n' "${headers[@]}" >"$FAKE_CURL_HEADERS_FILE"
  printf '%s' "$url" >"$FAKE_CURL_URL_FILE"
  printf '{"ok":true}'
  exit 0
fi

printf 'unexpected:%s\n' "$url" >>"$FAKE_CURL_CALLS_FILE"
printf 'unexpected curl URL: %s\n' "$url" >&2
exit 101
FAKE_CURL
chmod +x "$FAKE_BIN/curl"

reset_capture() {
  : >"$CALLS_FILE"
  rm -f "$BODY_FILE" "$HEADERS_FILE" "$URL_FILE" "$AUDIENCE_FILE"
}

run_helper() {
  local helper="$1" manifest="$2" latest_id="$3" source_sha="$4" release_notes="$5"
  shift 5
  env \
    PATH="$FAKE_BIN:$ORIGINAL_PATH" \
    EVENT_ACTION=published \
    REPOSITORY="$FIXTURE_REPOSITORY" \
    RELEASE_ID="$FIXTURE_RELEASE_ID" \
    RELEASE_TAG="$FIXTURE_TAG" \
    RELEASE_NOTES="$release_notes" \
    RELEASE_PRERELEASE=false \
    RELEASE_DRAFT=false \
    LATEST_STABLE_ID="$latest_id" \
    SOURCE_ROOT="$SOURCE_ROOT" \
    SOURCE_SHA="$source_sha" \
    MARKETPLACE_MANIFEST="$manifest" \
    ACTIONS_ID_TOKEN_REQUEST_URL="$OIDC_URL" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN=fixture-request-token \
    EXPECTED_ENDPOINT="$FIXED_ENDPOINT" \
    FAKE_CURL_CALLS_FILE="$CALLS_FILE" \
    FAKE_CURL_BODY_FILE="$BODY_FILE" \
    FAKE_CURL_HEADERS_FILE="$HEADERS_FILE" \
    FAKE_CURL_URL_FILE="$URL_FILE" \
    FAKE_CURL_AUDIENCE_FILE="$AUDIENCE_FILE" \
    TOOL_RELEASES_ENDPOINT=https://attacker.invalid/constant \
    ANNOUNCE_URL=https://attacker.invalid/env \
    ANNOUNCE_SECRET=legacy-secret-must-be-ignored \
    OIDC_TOKEN=legacy-token-must-be-ignored \
    "$helper" "$@"
}

sha256_file_bytes() {
  local digest
  digest="$(sha256sum "$1")"
  printf '%s\n' "${digest%% *}"
}

assert_one_bound_request() {
  local expected_keys="$1" body_sha
  local -a calls headers
  mapfile -t calls <"$CALLS_FILE"
  [[ ${#calls[@]} -eq 2 && "${calls[0]}" == oidc && "${calls[1]}" == post ]] || die "valid fixture did not mint once and POST once"
  [[ "$(<"$URL_FILE")" == "$FIXED_ENDPOINT" ]] || die "request was redirected away from the fixed endpoint"
  mapfile -t headers <"$HEADERS_FILE"
  [[ ${#headers[@]} -eq 2 ]] || die "POST did not have exactly two explicit headers"
  [[ "${headers[0]}" == 'content-type: application/json' && "${headers[1]}" == authorization:\ Bearer\ fixture-token-* ]] || die "POST headers were not content-type plus bearer authentication"
  body_sha="$(sha256_file_bytes "$BODY_FILE")"
  [[ "$(<"$AUDIENCE_FILE")" == "$FIXED_ENDPOINT#sha256=$body_sha" ]] || die "OIDC audience did not bind the exact request bytes"
  [[ "$(jq -c 'keys | sort' "$BODY_FILE")" == "$expected_keys" ]] || die "request body had unexpected keys"
  grep -Fq "::add-mask::fixture-token-$body_sha" "$TMP/run-output" || die "OIDC token was not masked before send"
}

VALID_NOTES=$'## Highlights\n- First safe improvement\n- Second exact detail'
reset_capture
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$VALID_NOTES" >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "valid fixture"
fi
assert_one_bound_request '["notesSummary","operation","repository"]'
jq -e \
  --arg repository "$FIXTURE_REPOSITORY" \
  --arg notes $'First safe improvement\nSecond exact detail' \
  '.operation == "announce" and .repository == $repository and .notesSummary == $notes and (.notesSummary | length <= 600)' \
  "$BODY_FILE" >/dev/null || die "valid request body values"
pass "valid fixture sends one exact, bearer-authenticated request to the fixed endpoint"

reset_capture
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" '' >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "empty notes fixture"
fi
assert_one_bound_request '["operation","repository"]'
pass "empty notes omit notesSummary"

LONG_NOTES="$(python3 -c 'print("é" * 700, end="")')"
reset_capture
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$LONG_NOTES" >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "bounded notes fixture"
fi
assert_one_bound_request '["notesSummary","operation","repository"]'
jq -e '.notesSummary | length == 600' "$BODY_FILE" >/dev/null || die "notesSummary was not bounded to 600 characters"
pass "notesSummary is character-safe and bounded"

reset_capture
if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$VALID_NOTES" 'https://attacker.invalid/argument' >"$TMP/run-output" 2>&1; then
  die "alternate URL argument unexpectedly succeeded"
fi
[[ ! -s "$CALLS_FILE" ]] || die "alternate URL argument reached curl"
pass "alternate URL argument is rejected before mint or send"

expect_soft_no_http() {
  local label="$1" manifest="$2" latest_id="$3"
  reset_capture
  if ! run_helper "$HELPER" "$manifest" "$latest_id" "$SOURCE_SHA" "$VALID_NOTES" >"$TMP/run-output" 2>&1; then
    command cat "$TMP/run-output" >&2
    die "$label"
  fi
  [[ ! -s "$CALLS_FILE" ]] || die "$label minted or sent a request"
  pass "$label does not mint or send"
}

jq '(.plugins[0].name) = "other-tool"' "$MANIFEST" >"$TMP/mismatch-name.json"
expect_soft_no_http "manifest name mismatch" "$TMP/mismatch-name.json" "$FIXTURE_RELEASE_ID"

jq '(.plugins[0].source.sha) = "0000000000000000000000000000000000000000"' "$MANIFEST" >"$TMP/mismatch-sha.json"
expect_soft_no_http "manifest source SHA mismatch" "$TMP/mismatch-sha.json" "$FIXTURE_RELEASE_ID"

jq '(.plugins[0].metadata.version) = "9.9.9"' "$MANIFEST" >"$TMP/mismatch-version.json"
expect_soft_no_http "manifest version mismatch" "$TMP/mismatch-version.json" "$FIXTURE_RELEASE_ID"

jq '(.plugins[0].metadata.releaseId) = 43' "$MANIFEST" >"$TMP/mismatch-release-id.json"
expect_soft_no_http "manifest release ID mismatch" "$TMP/mismatch-release-id.json" "$FIXTURE_RELEASE_ID"

jq '(.plugins[0].metadata.releaseTag) = "v9.9.9"' "$MANIFEST" >"$TMP/mismatch-release-tag.json"
expect_soft_no_http "manifest release tag mismatch" "$TMP/mismatch-release-tag.json" "$FIXTURE_RELEASE_ID"

jq 'del(.plugins[0].card) | .plugins += [(.plugins[0] | .source.sha = "0000000000000000000000000000000000000000" | .card = {rows: ["wrong", "tuple", "card"], run: "No"})]' "$MANIFEST" >"$TMP/mismatch-card.json"
expect_soft_no_http "card on a nonmatching tuple" "$TMP/mismatch-card.json" "$FIXTURE_RELEASE_ID"

expect_soft_no_http "non-latest stable release" "$MANIFEST" 43

reset_capture
if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" '0000000000000000000000000000000000000000' "$VALID_NOTES" >"$TMP/run-output" 2>&1; then
  die "tag/source SHA mismatch unexpectedly succeeded"
fi
[[ ! -s "$CALLS_FILE" ]] || die "tag/source SHA mismatch minted or sent a request"
pass "tag-resolved source SHA mismatch fails before mint or send"

body_mutant="$TMP/helper-altered-body.sh"
replace_once "$HELPER" "$body_mutant" \
  'send_request "$request_body" "$request_sha" "$oidc_token"' \
  'send_request "${request_body}x" "$request_sha" "$oidc_token"'
chmod +x "$body_mutant"
expect_contract_reject "post-mint body substitution" "$WORKFLOW" "$body_mutant"
reset_capture
if run_helper "$body_mutant" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$VALID_NOTES" >"$TMP/run-output" 2>&1; then
  die "post-mint body mutation unexpectedly succeeded"
fi
mapfile -t mutation_calls <"$CALLS_FILE"
[[ ${#mutation_calls[@]} -eq 1 && "${mutation_calls[0]}" == oidc ]] || die "post-mint body mutation reached the endpoint"
grep -Fq 'request body changed after OIDC mint' "$TMP/run-output" || die "post-mint body mutation did not hit the digest guard"
pass "post-mint body alteration is rejected before POST"

printf '%d Tool Drop announce checks passed\n' "$pass_count"
