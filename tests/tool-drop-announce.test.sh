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
  local input_count secret_count fixed_count disable_count
  local release_index ancestry_index trusted_index manifest_index announce_index
  local release_ref trusted_repository trusted_ref trusted_path trusted_credentials
  local manifest_repository manifest_ref manifest_path manifest_credentials
  local ancestry_run expected_ancestry announce_run expected_announce manifest_env
  local send_block announce_block header_count mask_line send_line
  local retry_loop_line mint_line retry_loop_end_line

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
  grep -Fq -- '--arg releaseId "$RELEASE_ID"' "$helper" || return 1
  grep -Fq '{operation: $operation, repository: $repository, releaseId: $releaseId} + (if $notesSummary == "" then {} else {notesSummary: $notesSummary} end)' "$helper" || return 1
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
  grep -Fq '[[ "$1" =~ ^[1-9][0-9]*$ ]]' "$helper" || return 1
  grep -Fq 'is_positive_uint "$RELEASE_ID" || fail "RELEASE_ID must be a positive canonical decimal integer"' "$helper" || return 1
  grep -Fq 'is_positive_uint "$LATEST_STABLE_ID" || fail "LATEST_STABLE_ID must be a positive canonical decimal integer"' "$helper" || return 1
  ! grep -Fq -- '--location' "$helper" || return 1
  ! grep -Eq -- '--retry([ =]|$)' "$helper" || return 1
  grep -Fq 'ANNOUNCE_RESPONSE_DIR="$(mktemp -d)"' "$helper" || return 1
  grep -Fq 'trap cleanup_response_dir EXIT' "$helper" || return 1
  grep -Fq '[[ "$final_status" == 429 ]] || return 1' "$helper" || return 1
  grep -Fq '[[ "${values[0]}" =~ ^([1-9]|[1-9][0-9]|[1-5][0-9][0-9]|600)$ ]]' "$helper" || return 1
  grep -Fq 'retry_after="$(retry_after_seconds "$response_headers")"' "$helper" || return 1
  grep -Fq 'retry_delay=$((10#$retry_after + RETRY_LEASE_EXPIRY_CUSHION_SECONDS))' "$helper" || return 1
  grep -Fq 'sleep "$retry_delay"' "$helper" || return 1
  ! grep -Fq 'sleep "$retry_after"' "$helper" || return 1

  send_block="$(sed -n '/^send_request() {/,/^}/p' "$helper")"
  header_count="$(printf '%s\n' "$send_block" | grep -cE '^[[:space:]]+-H ' || true)"
  [[ "$header_count" == 2 ]] || return 1
  grep -Fq -- "-H 'content-type: application/json'" <<<"$send_block" || return 1
  grep -Fq -- '-H "authorization: Bearer $oidc_token"' <<<"$send_block" || return 1
  grep -Fq -- '--output "$response_body"' <<<"$send_block" || return 1
  grep -Fq -- '--dump-header "$response_headers"' <<<"$send_block" || return 1
  grep -Fq -- "--write-out '%{http_code}'" <<<"$send_block" || return 1
  ! grep -Fq -- '--fail-with-body' <<<"$send_block" || return 1
  grep -Fq 'curl --disable --silent --show-error' <<<"$send_block" || return 1

  disable_count="$({ grep -Fo -- '--disable' "$helper" || true; } | wc -l)"
  [[ "$disable_count" == 2 ]] || return 1
  grep -Fq 'curl --disable --fail-with-body --silent --show-error --get' "$helper" || return 1

  announce_block="$(sed -n '/^announce() {/,/^}/p' "$helper")"
  retry_loop_line="$({ grep -nFx '  for attempt in 1 2; do' <<<"$announce_block" || true; } | cut -d: -f1)"
  mint_line="$({ grep -nF 'oidc_token="$(mint_oidc_token "$audience")"' <<<"$announce_block" || true; } | cut -d: -f1)"
  retry_loop_end_line="$({ grep -nFx '  done' <<<"$announce_block" || true; } | cut -d: -f1)"
  [[ "$retry_loop_line" =~ ^[0-9]+$ && "$mint_line" =~ ^[0-9]+$ && "$retry_loop_end_line" =~ ^[0-9]+$ ]] || return 1
  ((retry_loop_line < mint_line && mint_line < retry_loop_end_line)) || return 1

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

mutant="$TMP/helper-omitted-release-id.sh"
replace_once "$HELPER" "$mutant" \
  '{operation: $operation, repository: $repository, releaseId: $releaseId} + (if $notesSummary == "" then {} else {notesSummary: $notesSummary} end)' \
  '{operation: $operation, repository: $repository} + (if $notesSummary == "" then {} else {notesSummary: $notesSummary} end)'
expect_contract_reject "omitted release ID body field" "$WORKFLOW" "$mutant"

mutant="$TMP/helper-numeric-release-id.sh"
replace_once "$HELPER" "$mutant" '--arg releaseId "$RELEASE_ID"' '--argjson releaseId "$RELEASE_ID"'
expect_contract_reject "numeric release ID body field" "$WORKFLOW" "$mutant"

mutant="$TMP/helper-zero-release-id.sh"
replace_once "$HELPER" "$mutant" '[[ "$1" =~ ^[1-9][0-9]*$ ]]' '[[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]'
expect_contract_reject "zero-permitting release ID validation" "$WORKFLOW" "$mutant"

mutant="$TMP/helper-mutable-send-body.sh"
replace_once "$HELPER" "$mutant" \
  'local -r request_body="$1" expected_sha="$2" oidc_token="$3"' \
  'local request_body="$1" expected_sha="$2" oidc_token="$3"'
expect_contract_reject "mutable send body" "$WORKFLOW" "$mutant"

mutant="$TMP/helper-post-check-body.sh"
replace_once "$HELPER" "$mutant" '--data-binary "$request_body"' '--data-binary "${request_body}x"'
expect_contract_reject "body alteration after digest guard" "$WORKFLOW" "$mutant"

mutant="$TMP/helper-mask-order.sh"
mask_statement="    printf '::add-mask::%s\\n' \"\$oidc_token\""
send_statement=$'    if ! send_request "$request_body" "$request_sha" "$oidc_token" \\\n      "$response_body" "$response_headers" http_status; then\n      break\n    fi'
replace_once "$HELPER" "$mutant" \
  "$mask_statement"$'\n'"$send_statement" \
  "$send_statement"$'\n'"$mask_statement"
expect_contract_reject "token mask ordering" "$WORKFLOW" "$mutant"

mutant="$TMP/helper-stale-retry-token.sh"
fresh_mint_block=$'  for attempt in 1 2; do\n    http_status=\'\'\n    if ! oidc_token="$(mint_oidc_token "$audience")"; then\n      fail "could not mint OIDC token"\n    fi'
stale_mint_block=$'  if ! oidc_token="$(mint_oidc_token "$audience")"; then\n    fail "could not mint OIDC token"\n  fi\n  for attempt in 1 2; do\n    http_status=\'\''
replace_once "$HELPER" "$mutant" "$fresh_mint_block" "$stale_mint_block"
expect_contract_reject "stale retry token" "$WORKFLOW" "$mutant"

mutant="$TMP/helper-unbounded-retry.sh"
replace_once "$HELPER" "$mutant" 'for attempt in 1 2; do' 'while true; do'
expect_contract_reject "unbounded retry loop" "$WORKFLOW" "$mutant"

mutant="$TMP/helper-wide-retry-after.sh"
replace_once "$HELPER" "$mutant" \
  '^([1-9]|[1-9][0-9]|[1-5][0-9][0-9]|600)$' \
  '^[1-9][0-9]*$'
expect_contract_reject "widened Retry-After validation" "$WORKFLOW" "$mutant"

mutant="$TMP/helper-raw-retry-sleep.sh"
raw_header_parse='retry_after="$(sed -n "s/^Retry-After: //p" "$response_headers")"'
replace_once "$HELPER" "$mutant" \
  'retry_after="$(retry_after_seconds "$response_headers")"' \
  "$raw_header_parse"
expect_contract_reject "raw Retry-After sleep" "$WORKFLOW" "$mutant"

mutant="$TMP/helper-ambient-curl-config.sh"
replace_once "$HELPER" "$mutant" \
  'curl --disable --silent --show-error' \
  'curl --silent --show-error'
expect_contract_reject "ambient curl configuration" "$WORKFLOW" "$mutant"

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
MINTED_TOKENS_FILE="$TMP/minted-tokens"
POST_TOKENS_FILE="$TMP/post-tokens"
SLEEP_DELAYS_FILE="$TMP/sleep-delays"
RESPONSE_PATHS_FILE="$TMP/response-paths"
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

[[ "${1:-}" == --disable ]] || exit 89

headers=()
request_body=''
audience_option=''
method=''
url=''
is_get=false
fail_with_body=false
output_file=''
dump_header_file=''
write_out=''

while (($# > 0)); do
  case "$1" in
    --disable)
      shift
      ;;
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
    --fail-with-body)
      fail_with_body=true
      shift
      ;;
    --output|-o)
      output_file="$2"
      shift 2
      ;;
    --dump-header|-D)
      dump_header_file="$2"
      shift 2
      ;;
    --write-out|-w)
      write_out="$2"
      shift 2
      ;;
    --silent|--show-error)
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
  printf 'mint\n' >>"$FAKE_CURL_CALLS_FILE"
  mint_index="$(grep -c '^mint$' "$FAKE_CURL_CALLS_FILE")"
  [[ "$is_get" == true && "$fail_with_body" == true && -z "$method" && -z "$request_body" ]] || exit 92
  [[ -z "$output_file" && -z "$dump_header_file" && -z "$write_out" ]] || exit 102
  [[ ${#headers[@]} -eq 1 && "${headers[0]}" == "authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" ]] || exit 93
  [[ "$audience_option" == audience=* ]] || exit 94
  audience="${audience_option#audience=}"
  [[ "$audience" == "$EXPECTED_ENDPOINT#sha256="* ]] || exit 95
  digest="${audience##*#sha256=}"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || exit 96
  printf '%s' "$audience" >"$FAKE_CURL_AUDIENCE_FILE"
  printf '%s' "$audience" >"$FAKE_CURL_AUDIENCE_FILE.$mint_index"
  token="fixture-token-$mint_index-$digest"
  printf '%s\n' "$token" >>"$FAKE_CURL_MINTED_TOKENS_FILE"
  printf '{"value":"%s"}' "$token"
  exit 0
fi

if [[ "$url" == "$EXPECTED_ENDPOINT" ]]; then
  printf 'post\n' >>"$FAKE_CURL_CALLS_FILE"
  post_index="$(grep -c '^post$' "$FAKE_CURL_CALLS_FILE")"
  [[ "$is_get" == false && "$method" == POST && -z "$audience_option" ]] || exit 97
  [[ ${#headers[@]} -eq 2 ]] || exit 98
  [[ "${headers[0]}" == 'content-type: application/json' ]] || exit 99
  expected_token="$(sed -n "${post_index}p" "$FAKE_CURL_MINTED_TOKENS_FILE")"
  [[ -n "$expected_token" && "${headers[1]}" == "authorization: Bearer $expected_token" ]] || exit 100
  printf '%s\n' "${headers[1]#authorization: Bearer }" >>"$FAKE_CURL_POST_TOKENS_FILE"
  printf '%s' "$request_body" >"$FAKE_CURL_BODY_FILE"
  printf '%s' "$request_body" >"$FAKE_CURL_BODY_FILE.$post_index"
  printf '%s\n' "${headers[@]}" >"$FAKE_CURL_HEADERS_FILE"
  printf '%s' "$url" >"$FAKE_CURL_URL_FILE"

  status_var="FAKE_POST_STATUS_$post_index"
  response_var="FAKE_RESPONSE_BODY_$post_index"
  retry_present_var="FAKE_RETRY_AFTER_PRESENT_$post_index"
  retry_value_var="FAKE_RETRY_AFTER_$post_index"
  retry_count_var="FAKE_RETRY_AFTER_COUNT_$post_index"
  informational_present_var="FAKE_INFORMATIONAL_RETRY_AFTER_PRESENT_$post_index"
  informational_value_var="FAKE_INFORMATIONAL_RETRY_AFTER_$post_index"
  transport_var="FAKE_TRANSPORT_EXIT_$post_index"
  status="${!status_var:-200}"
  response_body="${!response_var-}"
  retry_after_present="${!retry_present_var:-false}"
  retry_after="${!retry_value_var-}"
  retry_after_count="${!retry_count_var:-1}"
  informational_retry_after_present="${!informational_present_var:-false}"
  informational_retry_after="${!informational_value_var-}"
  transport_exit="${!transport_var:-0}"

  if [[ -n "$output_file" || -n "$dump_header_file" || -n "$write_out" ]]; then
    [[ -n "$output_file" && -n "$dump_header_file" && "$write_out" == '%{http_code}' ]] || exit 103
    printf '%s\n%s\n' "$output_file" "$dump_header_file" >>"$FAKE_CURL_RESPONSE_PATHS_FILE"
    printf '%s' "$response_body" >"$output_file"
    : >"$dump_header_file"
    if [[ "$informational_retry_after_present" == true ]]; then
      printf 'HTTP/1.1 103 Early Hints\r\n' >>"$dump_header_file"
      printf 'Retry-After: %s\r\n\r\n' "$informational_retry_after" >>"$dump_header_file"
    fi
    printf 'HTTP/1.1 %s Fixture\r\n' "$status" >>"$dump_header_file"
    if [[ "$retry_after_present" == true ]]; then
      [[ "$retry_after_count" =~ ^[1-9][0-9]*$ ]] || exit 104
      for ((header_index = 0; header_index < retry_after_count; header_index += 1)); do
        printf 'Retry-After: %s\r\n' "$retry_after" >>"$dump_header_file"
      done
    fi
    printf '\r\n' >>"$dump_header_file"
    if [[ "$transport_exit" != 0 ]]; then
      printf '000'
      exit "$transport_exit"
    fi
    printf '%s' "$status"
    exit 0
  fi

  printf '%s' "$response_body"
  if [[ "$fail_with_body" == true && ! "$status" =~ ^2[0-9][0-9]$ ]]; then
    exit 22
  fi
  exit "$transport_exit"
fi

printf 'unexpected:%s\n' "$url" >>"$FAKE_CURL_CALLS_FILE"
printf 'unexpected curl URL: %s\n' "$url" >&2
exit 101
FAKE_CURL
chmod +x "$FAKE_BIN/curl"

cat >"$FAKE_BIN/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 && "$1" =~ ^[1-9][0-9]*$ ]] || exit 110
printf 'sleep\n' >>"$FAKE_CURL_CALLS_FILE"
printf '%s\n' "$1" >>"$FAKE_SLEEP_DELAYS_FILE"
FAKE_SLEEP
chmod +x "$FAKE_BIN/sleep"

reset_capture() {
  : >"$CALLS_FILE"
  : >"$MINTED_TOKENS_FILE"
  : >"$POST_TOKENS_FILE"
  : >"$SLEEP_DELAYS_FILE"
  : >"$RESPONSE_PATHS_FILE"
  rm -f "$BODY_FILE" "$BODY_FILE".* "$HEADERS_FILE" "$URL_FILE" "$AUDIENCE_FILE" "$AUDIENCE_FILE".*
  FAKE_POST_STATUS_1=200
  FAKE_POST_STATUS_2=200
  FAKE_RESPONSE_BODY_1='{"ok":true}'
  FAKE_RESPONSE_BODY_2='{"ok":true}'
  FAKE_RETRY_AFTER_PRESENT_1=false
  FAKE_RETRY_AFTER_PRESENT_2=false
  FAKE_RETRY_AFTER_1=''
  FAKE_RETRY_AFTER_2=''
  FAKE_RETRY_AFTER_COUNT_1=1
  FAKE_RETRY_AFTER_COUNT_2=1
  FAKE_INFORMATIONAL_RETRY_AFTER_PRESENT_1=false
  FAKE_INFORMATIONAL_RETRY_AFTER_PRESENT_2=false
  FAKE_INFORMATIONAL_RETRY_AFTER_1=''
  FAKE_INFORMATIONAL_RETRY_AFTER_2=''
  FAKE_TRANSPORT_EXIT_1=0
  FAKE_TRANSPORT_EXIT_2=0
}

run_helper() {
  local helper="$1" manifest="$2" release_id="$3" latest_id="$4" source_sha="$5" release_notes="$6"
  shift 6
  env \
    PATH="$FAKE_BIN:$ORIGINAL_PATH" \
    EVENT_ACTION=published \
    REPOSITORY="$FIXTURE_REPOSITORY" \
    RELEASE_ID="$release_id" \
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
    FAKE_CURL_MINTED_TOKENS_FILE="$MINTED_TOKENS_FILE" \
    FAKE_CURL_POST_TOKENS_FILE="$POST_TOKENS_FILE" \
    FAKE_CURL_RESPONSE_PATHS_FILE="$RESPONSE_PATHS_FILE" \
    FAKE_SLEEP_DELAYS_FILE="$SLEEP_DELAYS_FILE" \
    FAKE_POST_STATUS_1="$FAKE_POST_STATUS_1" \
    FAKE_POST_STATUS_2="$FAKE_POST_STATUS_2" \
    FAKE_RESPONSE_BODY_1="$FAKE_RESPONSE_BODY_1" \
    FAKE_RESPONSE_BODY_2="$FAKE_RESPONSE_BODY_2" \
    FAKE_RETRY_AFTER_PRESENT_1="$FAKE_RETRY_AFTER_PRESENT_1" \
    FAKE_RETRY_AFTER_PRESENT_2="$FAKE_RETRY_AFTER_PRESENT_2" \
    FAKE_RETRY_AFTER_1="$FAKE_RETRY_AFTER_1" \
    FAKE_RETRY_AFTER_2="$FAKE_RETRY_AFTER_2" \
    FAKE_RETRY_AFTER_COUNT_1="$FAKE_RETRY_AFTER_COUNT_1" \
    FAKE_RETRY_AFTER_COUNT_2="$FAKE_RETRY_AFTER_COUNT_2" \
    FAKE_INFORMATIONAL_RETRY_AFTER_PRESENT_1="$FAKE_INFORMATIONAL_RETRY_AFTER_PRESENT_1" \
    FAKE_INFORMATIONAL_RETRY_AFTER_PRESENT_2="$FAKE_INFORMATIONAL_RETRY_AFTER_PRESENT_2" \
    FAKE_INFORMATIONAL_RETRY_AFTER_1="$FAKE_INFORMATIONAL_RETRY_AFTER_1" \
    FAKE_INFORMATIONAL_RETRY_AFTER_2="$FAKE_INFORMATIONAL_RETRY_AFTER_2" \
    FAKE_TRANSPORT_EXIT_1="$FAKE_TRANSPORT_EXIT_1" \
    FAKE_TRANSPORT_EXIT_2="$FAKE_TRANSPORT_EXIT_2" \
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

assert_response_capture_cleaned() {
  local expected_path_count="$1" label="$2" response_dir response_path
  local -a response_paths
  mapfile -t response_paths <"$RESPONSE_PATHS_FILE"
  [[ ${#response_paths[@]} -eq "$expected_path_count" ]] || die "$label did not capture the expected bounded response context"
  response_dir="$(dirname "${response_paths[0]}")"
  for response_path in "${response_paths[@]}"; do
    [[ "$(dirname "$response_path")" == "$response_dir" ]] || die "$label used response files from different directories"
  done
  [[ ! -e "$response_dir" ]] || die "$label left its response directory behind"
}

assert_one_bound_request() {
  local expected_keys="$1" body_sha
  local -a calls headers
  mapfile -t calls <"$CALLS_FILE"
  [[ ${#calls[@]} -eq 2 && "${calls[0]}" == mint && "${calls[1]}" == post ]] || die "valid fixture did not mint once and POST once"
  [[ "$(<"$URL_FILE")" == "$FIXED_ENDPOINT" ]] || die "request was redirected away from the fixed endpoint"
  mapfile -t headers <"$HEADERS_FILE"
  [[ ${#headers[@]} -eq 2 ]] || die "POST did not have exactly two explicit headers"
  [[ "${headers[0]}" == 'content-type: application/json' && "${headers[1]}" == authorization:\ Bearer\ fixture-token-* ]] || die "POST headers were not content-type plus bearer authentication"
  body_sha="$(sha256_file_bytes "$BODY_FILE")"
  [[ "$(<"$AUDIENCE_FILE")" == "$FIXED_ENDPOINT#sha256=$body_sha" ]] || die "OIDC audience did not bind the exact request bytes"
  [[ "$(jq -c 'keys | sort' "$BODY_FILE")" == "$expected_keys" ]] || die "request body had unexpected keys"
  grep -Fq "::add-mask::fixture-token-1-$body_sha" "$TMP/run-output" || die "OIDC token was not masked before send"
  grep -Fq "$FAKE_RESPONSE_BODY_1" "$TMP/run-output" || die "successful response body was not printed"
  assert_response_capture_cleaned 2 "single-attempt success"
}

VALID_NOTES=$'## Highlights\n- First safe improvement\n- Second exact detail'
reset_capture
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$VALID_NOTES" >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "valid fixture"
fi
assert_one_bound_request '["notesSummary","operation","releaseId","repository"]'
expected_valid_body='{"operation":"announce","repository":"fixture-tool","releaseId":"42","notesSummary":"First safe improvement\nSecond exact detail"}'
[[ "$(<"$BODY_FILE")" == "$expected_valid_body" ]] || die "valid request body bytes did not contain the exact release ID string"
jq -e \
  --arg repository "$FIXTURE_REPOSITORY" \
  --arg release_id "$FIXTURE_RELEASE_ID" \
  --arg notes $'First safe improvement\nSecond exact detail' \
  '.operation == "announce" and .repository == $repository and .releaseId == $release_id and (.releaseId | type == "string") and .notesSummary == $notes and (.notesSummary | length <= 600)' \
  "$BODY_FILE" >/dev/null || die "valid request body values"
pass "valid fixture sends one exact, bearer-authenticated request to the fixed endpoint"

baseline_audience="$(<"$AUDIENCE_FILE")"
CHANGED_RELEASE_ID='43'
CHANGED_MANIFEST="$TMP/release-43.json"
jq --argjson release_id "$CHANGED_RELEASE_ID" \
  '(.plugins[0].metadata.releaseId) = $release_id' \
  "$MANIFEST" >"$CHANGED_MANIFEST"
reset_capture
if ! run_helper "$HELPER" "$CHANGED_MANIFEST" "$CHANGED_RELEASE_ID" "$CHANGED_RELEASE_ID" "$SOURCE_SHA" "$VALID_NOTES" >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "changed release ID fixture"
fi
assert_one_bound_request '["notesSummary","operation","releaseId","repository"]'
expected_changed_body='{"operation":"announce","repository":"fixture-tool","releaseId":"43","notesSummary":"First safe improvement\nSecond exact detail"}'
[[ "$(<"$BODY_FILE")" == "$expected_changed_body" ]] || die "changed request body bytes did not contain the exact release ID string"
changed_audience="$(<"$AUDIENCE_FILE")"
[[ "$changed_audience" != "$baseline_audience" ]] || die "changing releaseId did not change the OIDC audience digest"
pass "changing the exact releaseId string changes the bound OIDC audience digest"

reset_capture
FAKE_POST_STATUS_1=299
FAKE_RESPONSE_BODY_1='{"ok":true,"status":299}'
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" '' >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "empty notes fixture"
fi
assert_one_bound_request '["operation","releaseId","repository"]'
[[ "$(<"$BODY_FILE")" == '{"operation":"announce","repository":"fixture-tool","releaseId":"42"}' ]] || die "empty-notes request body was not the exact reduced contract"
pass "empty notes omit notesSummary and a non-200 2xx response succeeds"

LONG_NOTES="$(python3 -c 'print("é" * 700, end="")')"
reset_capture
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$LONG_NOTES" >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "bounded notes fixture"
fi
assert_one_bound_request '["notesSummary","operation","releaseId","repository"]'
jq -e '.notesSummary | length == 600' "$BODY_FILE" >/dev/null || die "notesSummary was not bounded to 600 characters"
pass "notesSummary is character-safe and bounded"

reset_capture
FAKE_POST_STATUS_1=429
FAKE_RESPONSE_BODY_1='{"error":"lease held"}'
FAKE_RETRY_AFTER_PRESENT_1=true
FAKE_RETRY_AFTER_1=7
FAKE_POST_STATUS_2=200
FAKE_RESPONSE_BODY_2='{"ok":true,"attempt":2}'
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$VALID_NOTES" >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "bounded 429 recovery fixture"
fi
mapfile -t retry_calls <"$CALLS_FILE"
[[ "${retry_calls[*]}" == 'mint post sleep mint post' ]] || die "bounded recovery did not follow mint, post, sleep, mint, post"
[[ "$(<"$SLEEP_DELAYS_FILE")" == 9 ]] || die "bounded recovery did not add the two-second lease cushion"
cmp -s "$BODY_FILE.1" "$BODY_FILE.2" || die "bounded recovery changed request body bytes between attempts"
expected_retry_body='{"operation":"announce","repository":"fixture-tool","releaseId":"42","notesSummary":"First safe improvement\nSecond exact detail"}'
[[ "$(<"$BODY_FILE.1")" == "$expected_retry_body" ]] || die "bounded recovery changed the compact request body"
cmp -s "$AUDIENCE_FILE.1" "$AUDIENCE_FILE.2" || die "bounded recovery changed the body-bound audience"
retry_body_sha="$(sha256_file_bytes "$BODY_FILE.1")"
[[ "$(<"$AUDIENCE_FILE.1")" == "$FIXED_ENDPOINT#sha256=$retry_body_sha" ]] || die "bounded recovery audience did not bind the retried body bytes"
mapfile -t retry_tokens <"$MINTED_TOKENS_FILE"
[[ ${#retry_tokens[@]} -eq 2 && "${retry_tokens[0]}" != "${retry_tokens[1]}" ]] || die "bounded recovery reused the first OIDC token"
cmp -s "$MINTED_TOKENS_FILE" "$POST_TOKENS_FILE" || die "a POST did not use its corresponding freshly minted token"
grep -Fq "::add-mask::${retry_tokens[0]}" "$TMP/run-output" || die "first retry fixture token was not masked"
grep -Fq "::add-mask::${retry_tokens[1]}" "$TMP/run-output" || die "second retry fixture token was not masked"
grep -Fq "$FAKE_RESPONSE_BODY_2" "$TMP/run-output" || die "successful retry response body was not printed"
mapfile -t retry_response_paths <"$RESPONSE_PATHS_FILE"
[[ ${#retry_response_paths[@]} -eq 4 ]] || die "bounded recovery did not use response/header capture files for both attempts"
retry_response_dir="$(dirname "${retry_response_paths[0]}")"
for response_path in "${retry_response_paths[@]}"; do
  [[ "$(dirname "$response_path")" == "$retry_response_dir" ]] || die "response/header files did not share one unique temporary directory"
done
[[ ! -e "$retry_response_dir" ]] || die "bounded recovery did not clean its response directory"
pass "a first 429 sleeps for Retry-After plus two and retries once with a fresh body-bound token"

expect_first_post_failure() {
  local label="$1" status="$2" retry_present="$3" retry_value="$4"
  local retry_count="$5" transport_exit="$6" expected_message="$7" response_body="$8"
  local -a calls minted_tokens

  reset_capture
  FAKE_POST_STATUS_1="$status"
  FAKE_RESPONSE_BODY_1="$response_body"
  FAKE_RETRY_AFTER_PRESENT_1="$retry_present"
  FAKE_RETRY_AFTER_1="$retry_value"
  FAKE_RETRY_AFTER_COUNT_1="$retry_count"
  FAKE_TRANSPORT_EXIT_1="$transport_exit"
  if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$VALID_NOTES" >"$TMP/run-output" 2>&1; then
    die "$label unexpectedly succeeded"
  fi

  mapfile -t calls <"$CALLS_FILE"
  [[ "${calls[*]}" == 'mint post' ]] || die "$label caused an unintended retry, mint, or sleep"
  [[ ! -s "$SLEEP_DELAYS_FILE" ]] || die "$label slept before failing"
  mapfile -t minted_tokens <"$MINTED_TOKENS_FILE"
  [[ ${#minted_tokens[@]} -eq 1 ]] || die "$label did not mint exactly once"
  cmp -s "$MINTED_TOKENS_FILE" "$POST_TOKENS_FILE" || die "$label POST did not use its freshly minted token"
  grep -Fq "$expected_message" "$TMP/run-output" || die "$label did not print useful failure context"
  assert_response_capture_cleaned 2 "$label"
  pass "$label"
}

expect_first_post_failure \
  "missing Retry-After is rejected without retry" \
  429 false '' 1 0 'canonical Retry-After' '{"error":"missing retry delay"}'
expect_first_post_failure \
  "noncanonical Retry-After is rejected without retry" \
  429 true 07 1 0 'canonical Retry-After' '{"error":"leading zero"}'
expect_first_post_failure \
  "malformed Retry-After is rejected without retry" \
  429 true 'Wed, 21 Oct 2015 07:28:00 GMT' 1 0 'canonical Retry-After' '{"error":"HTTP date"}'
expect_first_post_failure \
  "folded Retry-After is rejected without retry" \
  429 true $'7\r\n 00' 1 0 'canonical Retry-After' '{"error":"obsolete folded value"}'
expect_first_post_failure \
  "zero Retry-After is rejected without retry" \
  429 true 0 1 0 'canonical Retry-After' '{"error":"zero delay"}'
expect_first_post_failure \
  "Retry-After above 600 is rejected without retry" \
  429 true 601 1 0 'canonical Retry-After' '{"error":"delay too large"}'
expect_first_post_failure \
  "duplicate Retry-After is rejected without retry" \
  429 true 7 2 0 'canonical Retry-After' '{"error":"duplicate delay"}'

reset_capture
FAKE_POST_STATUS_1=429
FAKE_RESPONSE_BODY_1='{"error":"final response has no delay"}'
FAKE_INFORMATIONAL_RETRY_AFTER_PRESENT_1=true
FAKE_INFORMATIONAL_RETRY_AFTER_1=7
if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$VALID_NOTES" >"$TMP/run-output" 2>&1; then
  die "informational Retry-After unexpectedly authorized a retry"
fi
mapfile -t informational_calls <"$CALLS_FILE"
[[ "${informational_calls[*]}" == 'mint post' ]] || die "an informational Retry-After authorized a retry for the final 429"
[[ ! -s "$SLEEP_DELAYS_FILE" ]] || die "an informational Retry-After reached sleep"
grep -Fq 'canonical Retry-After' "$TMP/run-output" || die "missing final-response Retry-After did not print useful context"
assert_response_capture_cleaned 2 "informational Retry-After"
pass "Retry-After from an earlier HTTP block cannot authorize a final 429 retry"

expect_first_post_failure \
  "HTTP 401 is rejected without retry" \
  401 false '' 1 0 'HTTP 401' '{"error":"unauthorized"}'
expect_first_post_failure \
  "HTTP 403 is rejected without retry" \
  403 false '' 1 0 'HTTP 403' '{"error":"forbidden"}'
expect_first_post_failure \
  "HTTP 409 is rejected without retry" \
  409 false '' 1 0 'HTTP 409' '{"error":"tuple conflict"}'
expect_first_post_failure \
  "redirect response is rejected without following or retrying" \
  302 false '' 1 0 'HTTP 302' '{"error":"redirect refused"}'

bounded_503_body="prefix-visible-$(python3 -c 'print("x" * 3000, end="")')-tail-must-not-print"
expect_first_post_failure \
  "HTTP 503 is rejected without retry and with bounded context" \
  503 false '' 1 0 'HTTP 503' "$bounded_503_body"
grep -Fq 'prefix-visible-' "$TMP/run-output" || die "HTTP 503 context omitted the bounded response prefix"
grep -Fq 'response body truncated' "$TMP/run-output" || die "HTTP 503 context did not report truncation"
! grep -Fq 'tail-must-not-print' "$TMP/run-output" || die "HTTP 503 context exceeded its fixed bound"

expect_first_post_failure \
  "curl transport failure is rejected without retry" \
  200 false '' 1 7 'transport failure (curl exit 7)' '{"error":"partial transport body"}'

reset_capture
FAKE_POST_STATUS_1=429
FAKE_RESPONSE_BODY_1='{"error":"first lease"}'
FAKE_RETRY_AFTER_PRESENT_1=true
FAKE_RETRY_AFTER_1=3
FAKE_POST_STATUS_2=429
FAKE_RESPONSE_BODY_2='{"error":"second lease"}'
FAKE_RETRY_AFTER_PRESENT_2=true
FAKE_RETRY_AFTER_2=3
if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$VALID_NOTES" >"$TMP/run-output" 2>&1; then
  die "second HTTP 429 unexpectedly succeeded"
fi
mapfile -t second_429_calls <"$CALLS_FILE"
[[ "${second_429_calls[*]}" == 'mint post sleep mint post' ]] || die "second HTTP 429 escaped the one-retry bound"
[[ "$(<"$SLEEP_DELAYS_FILE")" == 5 ]] || die "second HTTP 429 fixture did not use the first validated delay plus cushion"
mapfile -t second_429_tokens <"$MINTED_TOKENS_FILE"
[[ ${#second_429_tokens[@]} -eq 2 && "${second_429_tokens[0]}" != "${second_429_tokens[1]}" ]] || die "second HTTP 429 did not use two distinct mints"
cmp -s "$MINTED_TOKENS_FILE" "$POST_TOKENS_FILE" || die "second HTTP 429 POST did not use its corresponding fresh token"
grep -Fq 'remained HTTP 429 after one retry' "$TMP/run-output" || die "second HTTP 429 did not print bounded failure context"
assert_response_capture_cleaned 4 "second HTTP 429"
pass "a second HTTP 429 fails after exactly one bounded retry"

reset_capture
if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$VALID_NOTES" 'https://attacker.invalid/argument' >"$TMP/run-output" 2>&1; then
  die "alternate URL argument unexpectedly succeeded"
fi
[[ ! -s "$CALLS_FILE" ]] || die "alternate URL argument reached curl"
pass "alternate URL argument is rejected before mint or send"

expect_invalid_id_no_http() {
  local label="$1" release_id="$2" latest_id="$3" expected_message="$4"
  reset_capture
  if run_helper "$HELPER" "$MANIFEST" "$release_id" "$latest_id" "$SOURCE_SHA" "$VALID_NOTES" >"$TMP/run-output" 2>&1; then
    die "$label unexpectedly succeeded"
  fi
  [[ ! -s "$CALLS_FILE" ]] || die "$label minted or sent a request"
  grep -Fxq "error: $expected_message" "$TMP/run-output" || die "$label did not emit the deterministic validation error"
  pass "$label fails before mint or send"
}

release_id_error='RELEASE_ID must be a positive canonical decimal integer'
latest_id_error='LATEST_STABLE_ID must be a positive canonical decimal integer'
expect_invalid_id_no_http "zero RELEASE_ID" 0 "$FIXTURE_RELEASE_ID" "$release_id_error"
expect_invalid_id_no_http "leading-zero RELEASE_ID" 042 "$FIXTURE_RELEASE_ID" "$release_id_error"
expect_invalid_id_no_http "malformed RELEASE_ID" invalid "$FIXTURE_RELEASE_ID" "$release_id_error"
expect_invalid_id_no_http "zero LATEST_STABLE_ID" "$FIXTURE_RELEASE_ID" 0 "$latest_id_error"
expect_invalid_id_no_http "leading-zero LATEST_STABLE_ID" "$FIXTURE_RELEASE_ID" 042 "$latest_id_error"
expect_invalid_id_no_http "malformed LATEST_STABLE_ID" "$FIXTURE_RELEASE_ID" invalid "$latest_id_error"

expect_soft_no_http() {
  local label="$1" manifest="$2" latest_id="$3"
  reset_capture
  if ! run_helper "$HELPER" "$manifest" "$FIXTURE_RELEASE_ID" "$latest_id" "$SOURCE_SHA" "$VALID_NOTES" >"$TMP/run-output" 2>&1; then
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
if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" '0000000000000000000000000000000000000000' "$VALID_NOTES" >"$TMP/run-output" 2>&1; then
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
if run_helper "$body_mutant" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$VALID_NOTES" >"$TMP/run-output" 2>&1; then
  die "post-mint body mutation unexpectedly succeeded"
fi
mapfile -t mutation_calls <"$CALLS_FILE"
[[ ${#mutation_calls[@]} -eq 1 && "${mutation_calls[0]}" == mint ]] || die "post-mint body mutation reached the endpoint"
grep -Fq 'request body changed after OIDC mint' "$TMP/run-output" || die "post-mint body mutation did not hit the digest guard"
pass "post-mint body alteration is rejected before POST"

printf '%d Tool Drop announce checks passed\n' "$pass_count"
