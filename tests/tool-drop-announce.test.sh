#!/usr/bin/env bash
# Static mutation needles quote shell/Actions expressions, and the fake HTTP
# plan is intentionally addressed through dynamically named variables.
# shellcheck disable=SC2016,SC2034
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
  local current_index release_index ancestry_index trusted_index manifest_index stable_index announce_index
  local release_ref trusted_repository trusted_ref trusted_path trusted_credentials
  local manifest_repository manifest_ref manifest_path manifest_credentials
  local current_run stable_run expected_stable ancestry_run expected_ancestry announce_run expected_announce manifest_env
  local current_env_count stable_env_count announce_env_count current_release_file step_count gated_step_count
  local concurrency_group concurrency_cancel concurrency_cancel_tag
  local send_block announce_block header_count mask_line send_line utf16_width_count
  local retry_loop_line mint_line retry_loop_end_line

  input_count="$(yq -r '.on.workflow_call.inputs // {} | length' "$workflow")" || return 1
  secret_count="$(yq -r '.on.workflow_call.secrets // {} | length' "$workflow")" || return 1
  [[ "$input_count" == 0 && "$secret_count" == 0 ]] || return 1
  ! grep -Eq 'announce-url|x-tool-release-announce-secret' "$workflow" "$helper" || return 1
  ! grep -Fq 'ANNOUNCE_URL' "$workflow" || return 1
  ! grep -Fq 'ANNOUNCE_SECRET' "$workflow" || return 1
  ! grep -Fq 'OIDC_TOKEN' "$workflow" || return 1
  grep -Fq 'unset ANNOUNCE_URL OIDC_TOKEN RELEASE_NAME RELEASE_URL RELEASE_NOTES RELEASE_PRERELEASE RELEASE_DRAFT' "$helper" || return 1
  grep -Fq '[[ -z "${ANNOUNCE_SECRET:-}" ]] || fail "legacy workflow secret authentication is not supported"' "$helper" || return 1
  [[ "$(yq -r 'has("concurrency")' "$workflow")" == false ]] || return 1

  concurrency_group="$(yq -r '.jobs.announce.concurrency.group' "$workflow")" || return 1
  concurrency_cancel="$(yq -r '.jobs.announce.concurrency.cancel-in-progress' "$workflow")" || return 1
  concurrency_cancel_tag="$(yq -r '.jobs.announce.concurrency.cancel-in-progress | tag' "$workflow")" || return 1
  [[ "$concurrency_group" == 'hov-tool-drop-announce-${{ github.repository }}-${{ github.event.release.id }}' ]] || return 1
  [[ "$concurrency_cancel" == true && "$concurrency_cancel_tag" == '!!bool' ]] || return 1
  [[ "$(yq -r '.jobs.announce | has("if")' "$workflow")" == false ]] || return 1

  fixed_count="$({ grep -Fo "$FIXED_ENDPOINT" "$helper" || true; } | wc -l)"
  [[ "$fixed_count" == 1 ]] || return 1
  grep -Fxq "readonly TOOL_RELEASES_ENDPOINT='$FIXED_ENDPOINT'" "$helper" || return 1
  ! grep -Fq "$FIXED_ENDPOINT" "$workflow" || return 1

  current_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Resolve current release eligibility") | .key' "$workflow")" || return 1
  release_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Check out release commit") | .key' "$workflow")" || return 1
  ancestry_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Require release commit on default branch") | .key' "$workflow")" || return 1
  trusted_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Check out trusted workflow helper") | .key' "$workflow")" || return 1
  manifest_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Check out current marketplace manifest") | .key' "$workflow")" || return 1
  stable_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Resolve latest stable release") | .key' "$workflow")" || return 1
  announce_index="$(yq -r '.jobs.announce.steps | to_entries | .[] | select(.value.name == "Announce release") | .key' "$workflow")" || return 1
  [[ "$current_index" == 0 && "$release_index" =~ ^[0-9]+$ && "$ancestry_index" =~ ^[0-9]+$ && "$trusted_index" =~ ^[0-9]+$ && "$manifest_index" =~ ^[0-9]+$ && "$stable_index" =~ ^[0-9]+$ && "$announce_index" =~ ^[0-9]+$ ]] || return 1
  ((current_index < release_index && release_index + 1 == ancestry_index && ancestry_index < trusted_index && trusted_index < manifest_index && manifest_index < stable_index && stable_index < announce_index)) || return 1

  step_count="$(yq -r '.jobs.announce.steps | length' "$workflow")" || return 1
  gated_step_count="$(yq -r '[.jobs.announce.steps[] | select(.name != "Resolve current release eligibility" and .["if"] == "steps.current.outputs.eligible == '\''true'\''")] | length' "$workflow")" || return 1
  [[ "$gated_step_count" == "$((step_count - 1))" ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[0] | has("if")' "$workflow")" == false ]] || return 1

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

  current_release_file='${{ runner.temp }}/hov-tool-drop-current-release.json'
  current_env_count="$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve current release eligibility") | .env | length' "$workflow")" || return 1
  [[ "$current_env_count" == 4 ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve current release eligibility") | .env.GH_TOKEN' "$workflow")" == '${{ github.token }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve current release eligibility") | .env.RELEASE_ID' "$workflow")" == '${{ github.event.release.id }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve current release eligibility") | .env.RELEASE_TAG' "$workflow")" == '${{ github.event.release.tag_name }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve current release eligibility") | .env.CURRENT_RELEASE_FILE' "$workflow")" == "$current_release_file" ]] || return 1
  current_run="$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve current release eligibility") | .run' "$workflow")" || return 1
  [[ "$current_run" == *'gh api "repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID" >"$CURRENT_RELEASE_FILE"'* ]] || return 1
  [[ "$current_run" == *'((.id | tostring) == $expected_id)'* ]] || return 1
  [[ "$current_run" == *'(.tag_name == $expected_tag)'* ]] || return 1
  [[ "$current_run" == *'(.body == null or (.body | type == "string"))'* ]] || return 1
  [[ "$current_run" == *'then ((.draft | not) and (.prerelease | not))'* ]] || return 1
  [[ "$current_run" == *'echo "eligible=$eligible" >> "$GITHUB_OUTPUT"'* ]] || return 1
  [[ "$current_run" != *'releases/latest'* && "$current_run" != *'${{'* ]] || return 1

  stable_env_count="$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve latest stable release") | .env | length' "$workflow")" || return 1
  [[ "$stable_env_count" == 1 ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve latest stable release") | .env.GH_TOKEN' "$workflow")" == '${{ github.token }}' ]] || return 1
  stable_run="$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve latest stable release") | .run' "$workflow")" || return 1
  expected_stable=$'latest_id="$(gh api "repos/$GITHUB_REPOSITORY/releases/latest" --jq .id)"\ntest -n "$latest_id"\necho "id=$latest_id" >> "$GITHUB_OUTPUT"'
  [[ "$stable_run" == "$expected_stable" && "$stable_run" != *'${{'* ]] || return 1

  announce_run="$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .run' "$workflow")" || return 1
  manifest_env="$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env.MARKETPLACE_MANIFEST' "$workflow")" || return 1
  announce_env_count="$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env | length' "$workflow")" || return 1
  expected_announce=$'source_sha="$(git rev-list -n 1 "refs/tags/$RELEASE_TAG")"\nexport SOURCE_SHA="$source_sha"\n'
  expected_announce+="./$trusted_path/scripts/tool-drop-announce.sh"
  [[ "$announce_run" == "$expected_announce" ]] || return 1
  [[ "$announce_env_count" == 8 ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env.EVENT_ACTION' "$workflow")" == '${{ github.event.action }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env.REPOSITORY' "$workflow")" == '${{ github.event.repository.name }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env.RELEASE_ID' "$workflow")" == '${{ github.event.release.id }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env.RELEASE_TAG' "$workflow")" == '${{ github.event.release.tag_name }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env.CURRENT_RELEASE_FILE' "$workflow")" == "$current_release_file" ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env.LATEST_STABLE_ID' "$workflow")" == '${{ steps.stable.outputs.id }}' ]] || return 1
  [[ "$(yq -r '.jobs.announce.steps[] | select(.name == "Announce release") | .env.SOURCE_ROOT' "$workflow")" == '${{ github.workspace }}' ]] || return 1
  [[ "$manifest_env" == '${{ github.workspace }}'"/$manifest_path/.claude-plugin/marketplace.json" ]] || return 1
  ! grep -Eq 'github\.event\.release\.(body|draft|prerelease)' "$workflow" || return 1
  ! grep -Fq 'ACTIONS_ID_TOKEN_REQUEST_URL' "$workflow" || return 1

  grep -Fq 'readonly request_body' "$helper" || return 1
  [[ "$({ grep -Fo -- '--arg releaseId "$RELEASE_ID"' "$helper" || true; } | wc -l)" == 2 ]] || return 1
  grep -Fq '{operation: $operation, repository: $repository, releaseId: $releaseId} + (if $notesSummary == "" then {} else {notesSummary: $notesSummary} end)' "$helper" || return 1
  grep -Fq 'local -r request_body="$1" expected_sha="$2" oidc_token="$3"' "$helper" || return 1
  grep -Fq 'request_sha="$(sha256_bytes "$request_body")"' "$helper" || return 1
  grep -Fq 'audience="${TOOL_RELEASES_ENDPOINT}#sha256=$request_sha"' "$helper" || return 1
  grep -Fxq "readonly LEGACY_OIDC_AUDIENCE='https://github.com/StartupBros-com'" "$helper" || return 1
  grep -Fq 'audience="$LEGACY_OIDC_AUDIENCE"' "$helper" || return 1
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
  grep -Fq 'require CURRENT_RELEASE_FILE' "$helper" || return 1
  grep -Fq '((.id | tostring) == $expected_id)' "$helper" || return 1
  grep -Fq '(.tag_name == $expected_tag)' "$helper" || return 1
  grep -Fq 'has("body")' "$helper" || return 1
  grep -Fq '(.body == null or (.body | type == "string"))' "$helper" || return 1
  grep -Fq '(.draft | type == "boolean")' "$helper" || return 1
  grep -Fq '(.prerelease | type == "boolean")' "$helper" || return 1
  grep -Fq 'CURRENT_RELEASE_NOTES="$(jq -jr' "$helper" || return 1
  grep -Fq 'notes="$(printf '\''%s'\'' "${CURRENT_RELEASE_NOTES:-}" | tr -d '\''\r'\'')"' "$helper" || return 1
  utf16_width_count="$({ grep -Fo 'width = 2 if ord(char) > 0xFFFF else 1' "$helper" || true; } | wc -l)"
  [[ "$utf16_width_count" == 2 ]] || return 1
  grep -Fq 'out.append(utf16_prefix(line, 180))' "$helper" || return 1
  grep -Fq 'print(utf16_prefix("\n".join(out), 600))' "$helper" || return 1
  grep -Fq 'if used + width > 600:' "$helper" || return 1
  grep -Fq '[[ "$EVENT_ACTION" == published || "$EVENT_ACTION" == edited ]] || fail "unsupported release action: $EVENT_ACTION"' "$helper" || return 1
  ! grep -Eq '(^|[[:space:]])(eval|source)[[:space:]].*CURRENT_RELEASE' "$helper" || return 1
  ! grep -Fq -- '--location' "$helper" || return 1
  ! grep -Eq -- '(^|[[:blank:]])-L([[:blank:]]|$)' "$helper" || return 1
  ! grep -Fq -- '--retry' "$helper" || return 1
  ! grep -Fq -- '--config' "$helper" || return 1
  ! grep -Eq -- '(^|[[:blank:]])-K([[:blank:]]|$)' "$helper" || return 1
  grep -Fq 'ANNOUNCE_RESPONSE_DIR="$(mktemp -d)"' "$helper" || return 1
  grep -Fq 'trap cleanup_response_dir EXIT' "$helper" || return 1
  grep -Fxq 'readonly ANNOUNCE_MAX_ATTEMPTS=8' "$helper" || return 1
  grep -Fxq 'readonly RETRY_JITTER_MAX_SECONDS=3' "$helper" || return 1
  grep -Fq '[[ "$expected_status" == 409 || "$expected_status" == 429 ]] || return 1' "$helper" || return 1
  grep -Fq '[[ "$final_status" == "$expected_status" ]] || return 1' "$helper" || return 1
  grep -Fq 'if [[ "$http_status" != 409 && "$http_status" != 429 ]]; then' "$helper" || return 1
  grep -Fq '[[ "${values[0]}" =~ ^([1-9]|[1-9][0-9]|[1-5][0-9][0-9]|600)$ ]]' "$helper" || return 1
  grep -Fq 'retry_after="$(retry_after_seconds "$response_headers" "$http_status")"' "$helper" || return 1
  grep -Fq 'digest="$(sha256_bytes "$jitter_repository:$jitter_release_id:$jitter_attempt")"' "$helper" || return 1
  grep -Fq '16#${digest:0:8} % (RETRY_JITTER_MAX_SECONDS + 1)' "$helper" || return 1
  grep -Fq 'retry_jitter="$(retry_jitter_seconds "$REPOSITORY" "$RELEASE_ID" "$attempt")"' "$helper" || return 1
  grep -Fq 'retry_delay=$((10#$retry_after + RETRY_LEASE_EXPIRY_CUSHION_SECONDS + retry_jitter))' "$helper" || return 1
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
  retry_loop_line="$({ grep -nFx '  for ((attempt = 1; attempt <= ANNOUNCE_MAX_ATTEMPTS; attempt += 1)); do' <<<"$announce_block" || true; } | cut -d: -f1)"
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

mutant="$TMP/workflow-no-concurrency-cancel.yml"
replace_once "$WORKFLOW" "$mutant" $'      cancel-in-progress: true\n' ''
expect_contract_reject "missing release concurrency cancellation" "$mutant" "$HELPER"

mutant="$TMP/workflow-wrong-concurrency-key.yml"
replace_once "$WORKFLOW" "$mutant" \
  'hov-tool-drop-announce-${{ github.repository }}-${{ github.event.release.id }}' \
  'hov-tool-drop-announce-${{ github.repository }}-${{ github.event.release.tag_name }}'
expect_contract_reject "release ID removed from concurrency key" "$mutant" "$HELPER"

mutant="$TMP/workflow-root-concurrency.yml"
replace_once "$WORKFLOW" "$mutant" $'permissions: {}\n' \
  $'permissions: {}\n\nconcurrency:\n  group: hov-tool-drop-announce\n  cancel-in-progress: true\n'
expect_contract_reject "root concurrency can cancel unrelated releases" "$mutant" "$HELPER"

mutant="$TMP/workflow-stale-job-filter.yml"
replace_once "$WORKFLOW" "$mutant" $'  announce:\n    concurrency:' \
  $'  announce:\n    if: github.event.release.draft == false && github.event.release.prerelease == false\n    concurrency:'
expect_contract_reject "stale event job filter" "$mutant" "$HELPER"

mutant="$TMP/workflow-missing-current-release-fetch.yml"
replace_once "$WORKFLOW" "$mutant" \
  'gh api "repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID" >"$CURRENT_RELEASE_FILE"' \
  ': >"$CURRENT_RELEASE_FILE"'
expect_contract_reject "missing current release fetch" "$mutant" "$HELPER"

mutant="$TMP/workflow-latest-as-current.yml"
replace_once "$WORKFLOW" "$mutant" \
  'gh api "repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID" >"$CURRENT_RELEASE_FILE"' \
  'gh api "repos/$GITHUB_REPOSITORY/releases/latest" >"$CURRENT_RELEASE_FILE"'
expect_contract_reject "current release fetch weakened to latest" "$mutant" "$HELPER"

mutant="$TMP/workflow-force-current-eligible.yml"
replace_once "$WORKFLOW" "$mutant" \
  'then ((.draft | not) and (.prerelease | not))' \
  'then true'
expect_contract_reject "draft and prerelease eligibility bypass" "$mutant" "$HELPER"

mutant="$TMP/workflow-unguarded-latest-stable.yml"
replace_once "$WORKFLOW" "$mutant" \
  $'      - name: Resolve latest stable release\n        if: steps.current.outputs.eligible == '\''true'\''' \
  $'      - name: Resolve latest stable release'
expect_contract_reject "latest stable lookup before eligibility" "$mutant" "$HELPER"

mutant="$TMP/workflow-stale-event-body.yml"
replace_once "$WORKFLOW" "$mutant" \
  $'          REPOSITORY: ${{ github.event.repository.name }}\n          RELEASE_ID: ${{ github.event.release.id }}\n' \
  $'          REPOSITORY: ${{ github.event.repository.name }}\n          RELEASE_ID: ${{ github.event.release.id }}\n          RELEASE_NOTES: ${{ github.event.release.body }}\n'
expect_contract_reject "stale event body authority" "$mutant" "$HELPER"

mutant="$TMP/workflow-missing-helper-current-file.yml"
replace_once "$WORKFLOW" "$mutant" \
  $'          RELEASE_TAG: ${{ github.event.release.tag_name }}\n          CURRENT_RELEASE_FILE: ${{ runner.temp }}/hov-tool-drop-current-release.json\n          LATEST_STABLE_ID:' \
  $'          RELEASE_TAG: ${{ github.event.release.tag_name }}\n          LATEST_STABLE_ID:'
expect_contract_reject "current release file not passed to helper" "$mutant" "$HELPER"

mutant="$TMP/workflow-published-only-announce-step.yml"
replace_once "$WORKFLOW" "$mutant" \
  $'      - name: Announce release\n        if: steps.current.outputs.eligible == '\''true'\''' \
  $'      - name: Announce release\n        if: steps.current.outputs.eligible == '\''true'\'' && github.event.action == '\''published'\'''
expect_contract_reject "published-only announce step" "$mutant" "$HELPER"

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
replace_once "$HELPER" "$mutant" \
  $'      --arg releaseId "$RELEASE_ID" \\\n      --arg notesSummary "$notes" \\' \
  $'      --argjson releaseId "$RELEASE_ID" \\\n      --arg notesSummary "$notes" \\'
expect_contract_reject "numeric release ID body field" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-zero-release-id.sh"
replace_once "$HELPER" "$mutant" '[[ "$1" =~ ^[1-9][0-9]*$ ]]' '[[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]'
expect_contract_reject "zero-permitting release ID validation" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-current-id-mismatch-accepted.sh"
replace_once "$HELPER" "$mutant" \
  '((.id | tostring) == $expected_id)' \
  '((.id | tostring) != $expected_id)'
expect_contract_reject "current release ID match removed" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-stale-event-notes.sh"
replace_once "$HELPER" "$mutant" \
  'notes="$(printf '\''%s'\'' "${CURRENT_RELEASE_NOTES:-}" | tr -d '\''\r'\'')"' \
  'notes="$(printf '\''%s'\'' "${RELEASE_NOTES:-}" | tr -d '\''\r'\'')"'
expect_contract_reject "stale event notes restored" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-codepoint-only-limit.sh"
python3 - "$HELPER" "$mutant" <<'PY'
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
text = source.read_text()
old = "width = 2 if ord(char) > 0xFFFF else 1"
if text.count(old) != 2:
    raise SystemExit("expected both UTF-16 width guards")
destination.write_text(text.replace(old, "width = 1"))
PY
expect_contract_reject "code-point-only notes limit" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-published-only.sh"
replace_once "$HELPER" "$mutant" \
  '[[ "$EVENT_ACTION" == published || "$EVENT_ACTION" == edited ]] || fail "unsupported release action: $EVENT_ACTION"' \
  '[[ "$EVENT_ACTION" == published ]] || fail "unsupported release action: $EVENT_ACTION"'
expect_contract_reject "edited release action removed" "$WORKFLOW" "$mutant"
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
fresh_mint_block=$'  for ((attempt = 1; attempt <= ANNOUNCE_MAX_ATTEMPTS; attempt += 1)); do\n    http_status=\'\'\n    if ! oidc_token="$(mint_oidc_token "$audience")"; then\n      fail "could not mint OIDC token"\n    fi'
stale_mint_block=$'  if ! oidc_token="$(mint_oidc_token "$audience")"; then\n    fail "could not mint OIDC token"\n  fi\n  for ((attempt = 1; attempt <= ANNOUNCE_MAX_ATTEMPTS; attempt += 1)); do\n    http_status=\'\''
replace_once "$HELPER" "$mutant" "$fresh_mint_block" "$stale_mint_block"
expect_contract_reject "OIDC mint outside retry loop" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-unbounded-retry.sh"
replace_once "$HELPER" "$mutant" \
  'for ((attempt = 1; attempt <= ANNOUNCE_MAX_ATTEMPTS; attempt += 1)); do' \
  'while true; do'
expect_contract_reject "unbounded retry loop" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-wider-attempt-budget.sh"
replace_once "$HELPER" "$mutant" 'readonly ANNOUNCE_MAX_ATTEMPTS=8' 'readonly ANNOUNCE_MAX_ATTEMPTS=9'
expect_contract_reject "widened retry attempt budget" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-incomplete-jitter-key.sh"
replace_once "$HELPER" "$mutant" \
  'sha256_bytes "$jitter_repository:$jitter_release_id:$jitter_attempt"' \
  'sha256_bytes "$jitter_repository:$jitter_release_id"'
expect_contract_reject "incomplete retry jitter key" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-wide-retry-after.sh"
replace_once "$HELPER" "$mutant" \
  '^([1-9]|[1-9][0-9]|[1-5][0-9][0-9]|600)$' \
  '^[1-9][0-9]*$'
expect_contract_reject "widened Retry-After validation" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-wide-retry-status.sh"
replace_once "$HELPER" "$mutant" \
  'if [[ "$http_status" != 409 && "$http_status" != 429 ]]; then' \
  'if [[ "$http_status" != 409 && "$http_status" != 429 && "$http_status" != 503 ]]; then'
expect_contract_reject "widened retry status set" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-raw-retry-sleep.sh"
raw_header_parse='retry_after="$(sed -n "s/^Retry-After: //p" "$response_headers")"'
replace_once "$HELPER" "$mutant" \
  'retry_after="$(retry_after_seconds "$response_headers" "$http_status")"' \
  "$raw_header_parse"
expect_contract_reject "raw Retry-After sleep" "$WORKFLOW" "$mutant"
mutant="$TMP/helper-ambient-curl-config.sh"
replace_once "$HELPER" "$mutant" \
  'curl --disable --silent --show-error' \
  'curl --silent --show-error'
expect_contract_reject "ambient curl configuration" "$WORKFLOW" "$mutant"

WORKFLOW_PROBE_BIN="$TMP/workflow-bin"
WORKFLOW_PROBE_CALLS="$TMP/workflow-gh-calls"
WORKFLOW_PROBE_OUTPUT="$TMP/workflow-output"
WORKFLOW_PROBE_RELEASE="$TMP/workflow-current-release.json"
mkdir -p "$WORKFLOW_PROBE_BIN"
cat >"$WORKFLOW_PROBE_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$WORKFLOW_PROBE_CALLS"
[[ "$*" == "api repos/fixture-owner/fixture-tool/releases/42" ]] || exit 120
printf '%s\n' '{"id":42,"tag_name":"v1.2.3","body":"prerelease notes","draft":false,"prerelease":true}'
FAKE_GH
chmod +x "$WORKFLOW_PROBE_BIN/gh"
: >"$WORKFLOW_PROBE_CALLS"
: >"$WORKFLOW_PROBE_OUTPUT"
workflow_current_run="$(yq -r '.jobs.announce.steps[] | select(.name == "Resolve current release eligibility") | .run' "$WORKFLOW")"
if ! env \
  PATH="$WORKFLOW_PROBE_BIN:$PATH" \
  GH_TOKEN=fixture-token \
  GITHUB_REPOSITORY=fixture-owner/fixture-tool \
  GITHUB_OUTPUT="$WORKFLOW_PROBE_OUTPUT" \
  RELEASE_ID=42 \
  RELEASE_TAG=v1.2.3 \
  CURRENT_RELEASE_FILE="$WORKFLOW_PROBE_RELEASE" \
  WORKFLOW_PROBE_CALLS="$WORKFLOW_PROBE_CALLS" \
  bash -c "$workflow_current_run" >"$TMP/workflow-probe-log" 2>&1; then
  command cat "$TMP/workflow-probe-log" >&2
  die "prerelease eligibility workflow probe"
fi
[[ "$(<"$WORKFLOW_PROBE_OUTPUT")" == 'eligible=false' ]] || die "prerelease eligibility did not emit false"
[[ "$(<"$WORKFLOW_PROBE_CALLS")" == 'api repos/fixture-owner/fixture-tool/releases/42' ]] || die "prerelease eligibility touched latest stable or another release"
grep -Fq 'Current release is draft or prerelease' "$TMP/workflow-probe-log" || die "prerelease eligibility did not report its soft no-op"
pass "prerelease-only repository resolves in current-state step without latest-stable lookup"

FIXTURE_REPOSITORY='fixture-tool'
FIXTURE_VERSION='1.2.3'
FIXTURE_TAG="v$FIXTURE_VERSION"
FIXTURE_RELEASE_ID='42'
SOURCE_ROOT="$TMP/source"
MANIFEST="$TMP/marketplace.json"
CURRENT_RELEASE_FILE="$TMP/current-release.json"
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
readonly FAKE_MAX_ATTEMPTS=8
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
  local attempt
  : >"$CALLS_FILE"
  : >"$MINTED_TOKENS_FILE"
  : >"$POST_TOKENS_FILE"
  : >"$SLEEP_DELAYS_FILE"
  : >"$RESPONSE_PATHS_FILE"
  rm -f "$BODY_FILE" "$BODY_FILE".* "$HEADERS_FILE" "$URL_FILE" "$AUDIENCE_FILE" "$AUDIENCE_FILE".*
  for ((attempt = 1; attempt <= FAKE_MAX_ATTEMPTS; attempt += 1)); do
    printf -v "FAKE_POST_STATUS_$attempt" '%s' 200
    printf -v "FAKE_RESPONSE_BODY_$attempt" '%s' '{"ok":true}'
    printf -v "FAKE_RETRY_AFTER_PRESENT_$attempt" '%s' false
    printf -v "FAKE_RETRY_AFTER_$attempt" '%s' ''
    printf -v "FAKE_RETRY_AFTER_COUNT_$attempt" '%s' 1
    printf -v "FAKE_INFORMATIONAL_RETRY_AFTER_PRESENT_$attempt" '%s' false
    printf -v "FAKE_INFORMATIONAL_RETRY_AFTER_$attempt" '%s' ''
    printf -v "FAKE_TRANSPORT_EXIT_$attempt" '%s' 0
  done
  write_current_release "$FIXTURE_RELEASE_ID" "$FIXTURE_TAG" "$VALID_NOTES" false false
}

write_current_release() {
  jq -n \
    --argjson id "$1" --arg tag_name "$2" --arg body "$3" \
    --argjson draft "$4" --argjson prerelease "$5" \
    '{id: $id, tag_name: $tag_name, body: $body, draft: $draft, prerelease: $prerelease}' \
    >"$CURRENT_RELEASE_FILE"
}

run_helper() {
  local helper="$1" manifest="$2" release_id="$3" latest_id="$4" source_sha="$5"
  local current_release_file="$6" event_action="$7"
  local attempt variable
  local -a fake_response_env=()
  shift 7
  for ((attempt = 1; attempt <= FAKE_MAX_ATTEMPTS; attempt += 1)); do
    for variable in FAKE_POST_STATUS FAKE_RESPONSE_BODY FAKE_RETRY_AFTER_PRESENT \
      FAKE_RETRY_AFTER FAKE_RETRY_AFTER_COUNT FAKE_INFORMATIONAL_RETRY_AFTER_PRESENT \
      FAKE_INFORMATIONAL_RETRY_AFTER FAKE_TRANSPORT_EXIT; do
      variable="${variable}_$attempt"
      fake_response_env+=("$variable=${!variable}")
    done
  done
  env \
    PATH="$FAKE_BIN:$ORIGINAL_PATH" \
    EVENT_ACTION="$event_action" \
    REPOSITORY="$FIXTURE_REPOSITORY" \
    RELEASE_ID="$release_id" \
    RELEASE_TAG="$FIXTURE_TAG" \
    CURRENT_RELEASE_FILE="$current_release_file" \
    RELEASE_NOTES="$HYPOTHETICAL_EVENT_NOTES" \
    RELEASE_PRERELEASE=true \
    RELEASE_DRAFT=true \
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
    "${fake_response_env[@]}" \
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
HYPOTHETICAL_EVENT_NOTES=$'## Highlights\n- Stale event notes must never win'
reset_capture
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
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
! grep -Fq 'Stale event notes' "$BODY_FILE" || die "hypothetical event notes overrode the current release file"
pass "validated current notes override stale event state in one exact fixed-endpoint request"

baseline_audience="$(<"$AUDIENCE_FILE")"
CHANGED_RELEASE_ID='43'
CHANGED_MANIFEST="$TMP/release-43.json"
jq --argjson release_id "$CHANGED_RELEASE_ID" \
  '(.plugins[0].metadata.releaseId) = $release_id' \
  "$MANIFEST" >"$CHANGED_MANIFEST"
reset_capture
write_current_release "$CHANGED_RELEASE_ID" "$FIXTURE_TAG" "$VALID_NOTES" false false
if ! run_helper "$HELPER" "$CHANGED_MANIFEST" "$CHANGED_RELEASE_ID" "$CHANGED_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
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
current_release_tmp="$TMP/current-release-null.json"
jq '.body = null' "$CURRENT_RELEASE_FILE" >"$current_release_tmp"
mv "$current_release_tmp" "$CURRENT_RELEASE_FILE"
FAKE_POST_STATUS_1=299
FAKE_RESPONSE_BODY_1='{"ok":true,"status":299}'
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "empty notes fixture"
fi
assert_one_bound_request '["operation","releaseId","repository"]'
[[ "$(<"$BODY_FILE")" == '{"operation":"announce","repository":"fixture-tool","releaseId":"42"}' ]] || die "empty-notes request body was not the exact reduced contract"
pass "empty notes omit notesSummary and a non-200 2xx response succeeds"

LONG_NOTES="$(python3 -c 'print("é" * 700, end="")')"
reset_capture
write_current_release "$FIXTURE_RELEASE_ID" "$FIXTURE_TAG" "$LONG_NOTES" false false
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "bounded notes fixture"
fi
assert_one_bound_request '["notesSummary","operation","releaseId","repository"]'
jq -e '.notesSummary | length == 600' "$BODY_FILE" >/dev/null || die "notesSummary was not bounded to 600 BMP characters"
pass "notesSummary is character-safe and bounded"

ASTRAL_NOTES="$(python3 -c 'print("😀" * 301, end="")')"
reset_capture
write_current_release "$FIXTURE_RELEASE_ID" "$FIXTURE_TAG" "$ASTRAL_NOTES" false false
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "UTF-16 bounded astral notes fixture"
fi
assert_one_bound_request '["notesSummary","operation","releaseId","repository"]'
python3 - "$BODY_FILE" <<'PY' || die "astral notes exceeded the endpoint UTF-16 limit"
import json
from pathlib import Path
import sys

notes = json.loads(Path(sys.argv[1]).read_text())["notesSummary"]
assert len(notes) == 300
assert len(notes.encode("utf-16-le")) // 2 == 600
PY
pass "astral notes are bounded to the endpoint's 600 UTF-16 units"

plan_response() {
  local attempt="$1" status="$2" retry_after="${3:-}"
  printf -v "FAKE_POST_STATUS_$attempt" '%s' "$status"
  printf -v "FAKE_RESPONSE_BODY_$attempt" '%s' "{\"status\":$status,\"attempt\":$attempt}"
  if [[ -n "$retry_after" ]]; then
    printf -v "FAKE_RETRY_AFTER_PRESENT_$attempt" '%s' true
    printf -v "FAKE_RETRY_AFTER_$attempt" '%s' "$retry_after"
  fi
}

assert_successful_retry() {
  local attempts="$1" label="$2" expected_delays="$3" attempt body_sha response_var token
  local -a calls expected_calls tokens
  mapfile -t calls <"$CALLS_FILE"
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    expected_calls+=(mint post)
    ((attempt == attempts)) || expected_calls+=(sleep)
  done
  [[ "${calls[*]}" == "${expected_calls[*]}" ]] || die "$label call order or attempt bound changed"
  [[ "$(<"$SLEEP_DELAYS_FILE")" == "$expected_delays" ]] || die "$label sleep sequence changed"
  mapfile -t tokens <"$MINTED_TOKENS_FILE"
  [[ ${#tokens[@]} -eq "$attempts" && "$(sort -u "$MINTED_TOKENS_FILE" | wc -l)" -eq "$attempts" ]] || die "$label reused an OIDC token"
  cmp -s "$MINTED_TOKENS_FILE" "$POST_TOKENS_FILE" || die "$label POST token did not match each fresh mint"
  for token in "${tokens[@]}"; do
    grep -Fq "::add-mask::$token" "$TMP/run-output" || die "$label left a token unmasked"
  done
  for ((attempt = 2; attempt <= attempts; attempt += 1)); do
    cmp -s "$BODY_FILE.1" "$BODY_FILE.$attempt" || die "$label changed request body bytes"
    cmp -s "$AUDIENCE_FILE.1" "$AUDIENCE_FILE.$attempt" || die "$label changed the body-bound audience"
  done
  body_sha="$(sha256_file_bytes "$BODY_FILE.1")"
  [[ "$(<"$AUDIENCE_FILE.1")" == "$FIXED_ENDPOINT#sha256=$body_sha" ]] || die "$label audience did not bind the immutable bytes"
  [[ ! -e "$BODY_FILE.$((attempts + 1))" && ! -e "$AUDIENCE_FILE.$((attempts + 1))" ]] || die "$label created an extra-attempt artifact"
  response_var="FAKE_RESPONSE_BODY_$attempts"
  grep -Fq "${!response_var}" "$TMP/run-output" || die "$label did not print its successful response"
  assert_response_capture_cleaned "$((attempts * 2))" "$label"
}

expect_three_attempt_recovery() {
  local label="$1" action="$2" first_status="$3" second_status="$4"
  reset_capture
  plan_response 1 "$first_status" 4
  plan_response 2 "$second_status" 3
  plan_response 3 200
  if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" "$action" >"$TMP/run-output" 2>&1; then
    command cat "$TMP/run-output" >&2
    die "$label"
  fi
  assert_successful_retry 3 "$label" $'8\n5'
  pass "$label succeeds with immutable bytes and fresh corresponding tokens"
}

expect_three_attempt_recovery "repeated 429 -> 429 -> 200 recovery" published 429 429
expect_three_attempt_recovery "repeated 409 -> 409 -> 200 recovery" published 409 409
expect_three_attempt_recovery "mixed 409 -> 429 -> 200 recovery" published 409 429

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
  if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
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

expect_invalid_retry_after_table() {
  local status="$1"
  expect_first_post_failure "HTTP $status missing Retry-After" "$status" false '' 1 0 'canonical Retry-After' '{"error":"missing retry delay"}'
  expect_first_post_failure "HTTP $status malformed Retry-After" "$status" true seven 1 0 'canonical Retry-After' '{"error":"malformed delay"}'
  expect_first_post_failure "HTTP $status duplicate Retry-After" "$status" true 7 2 0 'canonical Retry-After' '{"error":"duplicate delay"}'
  expect_first_post_failure "HTTP $status folded Retry-After" "$status" true $'7\r\n 00' 1 0 'canonical Retry-After' '{"error":"obsolete folded value"}'
  expect_first_post_failure "HTTP $status date Retry-After" "$status" true 'Wed, 21 Oct 2015 07:28:00 GMT' 1 0 'canonical Retry-After' '{"error":"HTTP date"}'
  expect_first_post_failure "HTTP $status zero Retry-After" "$status" true 0 1 0 'canonical Retry-After' '{"error":"zero delay"}'
  expect_first_post_failure "HTTP $status leading-zero Retry-After" "$status" true 07 1 0 'canonical Retry-After' '{"error":"leading zero"}'
  expect_first_post_failure "HTTP $status Retry-After above 600" "$status" true 601 1 0 'canonical Retry-After' '{"error":"delay too large"}'
}

for retry_status in 409 429; do
  expect_invalid_retry_after_table "$retry_status"
done

reset_capture
FAKE_POST_STATUS_1=429
FAKE_RESPONSE_BODY_1='{"error":"final response has no delay"}'
FAKE_INFORMATIONAL_RETRY_AFTER_PRESENT_1=true
FAKE_INFORMATIONAL_RETRY_AFTER_1=7
if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
  die "informational Retry-After unexpectedly authorized a retry"
fi
mapfile -t informational_calls <"$CALLS_FILE"
[[ "${informational_calls[*]}" == 'mint post' ]] || die "an informational Retry-After authorized a retry for the final 429"
[[ ! -s "$SLEEP_DELAYS_FILE" ]] || die "an informational Retry-After reached sleep"
grep -Fq 'canonical Retry-After' "$TMP/run-output" || die "missing final-response Retry-After did not print useful context"
assert_response_capture_cleaned 2 "informational Retry-After"
pass "Retry-After from an earlier HTTP block cannot authorize a final 429 retry"

reset_capture
plan_response 1 409 4
plan_response 2 200
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" edited >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "canonical 409 recovery fixture"
fi
assert_successful_retry 2 "canonical edited 409 recovery" 8
pass "an edited event accepts canonical 409 recovery"

reset_capture
for ((attempt = 1; attempt < FAKE_MAX_ATTEMPTS; attempt += 1)); do
  if ((attempt == 1)); then
    plan_response "$attempt" 409 3
  else
    plan_response "$attempt" 429 3
  fi
done
plan_response "$FAKE_MAX_ATTEMPTS" 200
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" edited >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "edited exact attempt-eight success fixture"
fi
assert_successful_retry 8 "edited 409 + six 429 + attempt-eight success" $'7\n5\n8\n7\n8\n5\n5'
pass "an edited event succeeds exactly on attempt eight without ninth-attempt artifacts"

expect_first_post_failure \
  "HTTP 401 is rejected without retry" \
  401 false '' 1 0 'HTTP 401' '{"error":"unauthorized"}'
expect_first_post_failure \
  "HTTP 403 is rejected without retry" \
  403 false '' 1 0 'HTTP 403' '{"error":"forbidden"}'
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
for ((attempt = 1; attempt <= FAKE_MAX_ATTEMPTS; attempt += 1)); do
  printf -v "FAKE_POST_STATUS_$attempt" '%s' 429
  printf -v "FAKE_RESPONSE_BODY_$attempt" '%s' "{\"error\":\"lease $attempt\"}"
  printf -v "FAKE_RETRY_AFTER_PRESENT_$attempt" '%s' true
  printf -v "FAKE_RETRY_AFTER_$attempt" '%s' 3
done
if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
  die "eight retryable responses unexpectedly succeeded"
fi
mapfile -t exhausted_calls <"$CALLS_FILE"
[[ "${exhausted_calls[*]}" == 'mint post sleep mint post sleep mint post sleep mint post sleep mint post sleep mint post sleep mint post sleep mint post' ]] || die "retry exhaustion crossed the eight-attempt boundary"
[[ "$(<"$SLEEP_DELAYS_FILE")" == $'7\n5\n8\n7\n8\n5\n5' ]] || die "retry exhaustion jitter sequence was not deterministic and bounded"
mapfile -t exhausted_tokens <"$MINTED_TOKENS_FILE"
[[ ${#exhausted_tokens[@]} -eq 8 && "$(sort -u "$MINTED_TOKENS_FILE" | wc -l)" -eq 8 ]] || die "retry exhaustion did not mint eight distinct tokens"
cmp -s "$MINTED_TOKENS_FILE" "$POST_TOKENS_FILE" || die "retry exhaustion POST token did not match each fresh mint"
for ((attempt = 2; attempt <= FAKE_MAX_ATTEMPTS; attempt += 1)); do
  cmp -s "$BODY_FILE.1" "$BODY_FILE.$attempt" || die "retry exhaustion changed request body bytes"
  cmp -s "$AUDIENCE_FILE.1" "$AUDIENCE_FILE.$attempt" || die "retry exhaustion changed the body-bound audience"
done
[[ ! -e "$BODY_FILE.9" && ! -e "$AUDIENCE_FILE.9" ]] || die "retry exhaustion created ninth-attempt artifacts"
grep -Fq 'exhausted 8 attempts' "$TMP/run-output" || die "retry exhaustion did not print the attempt budget"
assert_response_capture_cleaned 16 "retry exhaustion"
pass "eight retryable responses exhaust the budget without a ninth mint, POST, or sleep"

reset_capture
if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published 'https://attacker.invalid/argument' >"$TMP/run-output" 2>&1; then
  die "alternate URL argument unexpectedly succeeded"
fi
[[ ! -s "$CALLS_FILE" ]] || die "alternate URL argument reached curl"
pass "alternate URL argument is rejected before mint or send"

expect_invalid_id_no_http() {
  local label="$1" release_id="$2" latest_id="$3" expected_message="$4"
  reset_capture
  if run_helper "$HELPER" "$MANIFEST" "$release_id" "$latest_id" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
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

expect_current_release_noop() {
  local label="$1" draft="$2" prerelease="$3"
  reset_capture
  write_current_release "$FIXTURE_RELEASE_ID" "$FIXTURE_TAG" "$VALID_NOTES" "$draft" "$prerelease"
  if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" edited >"$TMP/run-output" 2>&1; then
    command cat "$TMP/run-output" >&2
    die "$label"
  fi
  [[ ! -s "$CALLS_FILE" ]] || die "$label minted or sent a request"
  grep -Fq 'prerelease or draft release ignored' "$TMP/run-output" || die "$label did not report its soft no-op"
  pass "$label soft-no-ops before mint or send"
}

expect_invalid_current_release() {
  local label="$1" filter="$2" invalid_file="$TMP/invalid-current-release.json"
  reset_capture
  jq "$filter" "$CURRENT_RELEASE_FILE" >"$invalid_file"
  mv "$invalid_file" "$CURRENT_RELEASE_FILE"
  if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
    die "$label unexpectedly succeeded"
  fi
  [[ ! -s "$CALLS_FILE" ]] || die "$label minted or sent a request"
  grep -Fq 'current release record is invalid or does not match expected identity' "$TMP/run-output" || die "$label did not fail closed"
  pass "$label fails before mint or send"
}

expect_current_release_noop "current prerelease" false true
expect_current_release_noop "current draft" true false
expect_invalid_current_release "mismatched current release ID" '.id = 43'
expect_invalid_current_release "mismatched current release tag" '.tag_name = "v9.9.9"'
expect_invalid_current_release "nonobject current release" '[.]'
expect_invalid_current_release "zero current release ID" '.id = 0'
expect_invalid_current_release "missing current release body" 'del(.body)'
expect_invalid_current_release "nonstring current release body" '.body = {}'
expect_invalid_current_release "nonboolean current release draft" '.draft = "false"'
expect_invalid_current_release "nonboolean current release prerelease" '.prerelease = 0'
expect_invalid_current_release "multiple current release records" '., .'

reset_capture
json_code_marker="$TMP/current-release-code-ran"
json_code_bullet="\$(touch $json_code_marker)"
write_current_release "$FIXTURE_RELEASE_ID" "$FIXTURE_TAG" "## Highlights
- $json_code_bullet" false false
if ! run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
  command cat "$TMP/run-output" >&2
  die "current release code-like notes fixture"
fi
assert_one_bound_request '["notesSummary","operation","releaseId","repository"]'
[[ ! -e "$json_code_marker" ]] || die "executable code came from current release JSON"
jq -e --arg notes "$json_code_bullet" '.notesSummary == $notes' "$BODY_FILE" >/dev/null || die "code-like current notes were not inert data"
pass "current release JSON remains inert data and cannot change endpoint or audience"

expect_soft_no_http() {
  local label="$1" manifest="$2" latest_id="$3" reason="${4:-}"
  reset_capture
  if ! run_helper "$HELPER" "$manifest" "$FIXTURE_RELEASE_ID" "$latest_id" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
    command cat "$TMP/run-output" >&2
    die "$label"
  fi
  [[ ! -s "$CALLS_FILE" ]] || die "$label minted or sent a request"
  # A skip that returns 0 is indistinguishable from a successful post unless it
  # says so loudly. Assert BOTH the human-visible error annotation and the
  # stable machine-readable marker, so this can never quietly regress to the
  # ::notice:: that made "green run, no card posted" the default outcome.
  if [[ -n "$reason" ]]; then
    grep -q "status=not-announced reason=$reason" "$TMP/run-output" \
      || die "$label did not emit the not-announced marker for reason=$reason"
    grep -q '::error title=Not announced::' "$TMP/run-output" \
      || die "$label skipped the announce without an error annotation"
    pass "$label reports not-announced loudly (reason=$reason)"
  fi
  pass "$label does not mint or send"
}

jq '(.plugins[0].name) = "other-tool"' "$MANIFEST" >"$TMP/mismatch-name.json"
expect_soft_no_http "manifest name mismatch" "$TMP/mismatch-name.json" "$FIXTURE_RELEASE_ID" not-listed

jq '(.plugins[0].source.sha) = "0000000000000000000000000000000000000000"' "$MANIFEST" >"$TMP/mismatch-sha.json"
expect_soft_no_http "manifest source SHA mismatch" "$TMP/mismatch-sha.json" "$FIXTURE_RELEASE_ID" not-listed

jq '(.plugins[0].metadata.version) = "9.9.9"' "$MANIFEST" >"$TMP/mismatch-version.json"
expect_soft_no_http "manifest version mismatch" "$TMP/mismatch-version.json" "$FIXTURE_RELEASE_ID" not-listed

jq '(.plugins[0].metadata.releaseId) = 43' "$MANIFEST" >"$TMP/mismatch-release-id.json"
expect_soft_no_http "manifest release ID mismatch" "$TMP/mismatch-release-id.json" "$FIXTURE_RELEASE_ID" not-listed

jq '(.plugins[0].metadata.releaseTag) = "v9.9.9"' "$MANIFEST" >"$TMP/mismatch-release-tag.json"
expect_soft_no_http "manifest release tag mismatch" "$TMP/mismatch-release-tag.json" "$FIXTURE_RELEASE_ID" not-listed

jq 'del(.plugins[0].card) | .plugins += [(.plugins[0] | .source.sha = "0000000000000000000000000000000000000000" | .card = {rows: ["wrong", "tuple", "card"], run: "No"})]' "$MANIFEST" >"$TMP/mismatch-card.json"
expect_soft_no_http "card on a nonmatching tuple" "$TMP/mismatch-card.json" "$FIXTURE_RELEASE_ID" no-card

expect_soft_no_http "non-latest stable release" "$MANIFEST" 43

reset_capture
if run_helper "$HELPER" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" '0000000000000000000000000000000000000000' "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
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
if run_helper "$body_mutant" "$MANIFEST" "$FIXTURE_RELEASE_ID" "$FIXTURE_RELEASE_ID" "$SOURCE_SHA" "$CURRENT_RELEASE_FILE" published >"$TMP/run-output" 2>&1; then
  die "post-mint body mutation unexpectedly succeeded"
fi
mapfile -t mutation_calls <"$CALLS_FILE"
[[ ${#mutation_calls[@]} -eq 1 && "${mutation_calls[0]}" == mint ]] || die "post-mint body mutation reached the endpoint"
grep -Fq 'request body changed after OIDC mint' "$TMP/run-output" || die "post-mint body mutation did not hit the digest guard"
pass "post-mint body alteration is rejected before POST"

printf '%d Tool Drop announce checks passed\n' "$pass_count"
