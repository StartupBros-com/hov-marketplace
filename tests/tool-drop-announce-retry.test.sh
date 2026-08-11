#!/usr/bin/env bash
# Tests for announce()'s bounded Retry-After retry (hov-marketplace#56).
# Stubs curl + sleep via PATH so no network and no real waiting happen.
# Scenario file: one line per curl call -> "<status> <body> [retry_after]".
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$HERE")"
PASS=0
FAIL=0

setup() {
  WORK="$(mktemp -d)"
  export STUB_SCENARIO="$WORK/scenario"
  export STUB_CALLS="$WORK/calls"
  export STUB_SLEEPS="$WORK/sleeps"
  : >"$STUB_CALLS"
  : >"$STUB_SLEEPS"
  mkdir -p "$WORK/bin"

  cat >"$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Serve the next scenario line: "<status> <body> [retry_after]".
echo x >>"$STUB_CALLS"
line_no="$(wc -l <"$STUB_CALLS")"
line="$(sed -n "${line_no}p" "$STUB_SCENARIO")"
status="${line%% *}"; rest="${line#* }"
body="${rest%% *}"; retry_after="${rest#* }"
out="" hdr=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[i]}" == "--output" ]] && out="${args[i+1]}"
  [[ "${args[i]}" == "--dump-header" ]] && hdr="${args[i+1]}"
done
printf '%s' "$body" >"$out"
{
  printf 'HTTP/1.1 %s X\r\n' "$status"
  if [[ "$retry_after" != "$rest" && -n "$retry_after" ]]; then
    printf 'Retry-After: %s\r\n' "$retry_after"
  fi
} >"$hdr"
printf '%s' "$status"
STUB
  cat >"$WORK/bin/sleep" <<'STUB'
#!/usr/bin/env bash
echo "$1" >>"$STUB_SLEEPS"
STUB
  chmod +x "$WORK/bin/curl" "$WORK/bin/sleep"

  export PATH="$WORK/bin:$PATH"
  export ANNOUNCE_URL="https://example.invalid/announce"
  export OIDC_TOKEN="stub-token"
  export REPOSITORY="stub-repo" RELEASE_ID="1" RELEASE_TAG="v0.0.1"
  export RELEASE_NAME="stub v0.0.1" RELEASE_URL="https://example.invalid/r"
  export RELEASE_NOTES=""
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/tool-drop-announce.sh"
}

report() {
  local name="$1" ok="$2"
  if [[ "$ok" == 0 ]]; then
    echo "ok - $name"
    PASS=$((PASS + 1))
  else
    echo "not ok - $name"
    FAIL=$((FAIL + 1))
  fi
}

# 1. Success first try: one call, body on stdout, no sleeps.
(
  setup
  printf '200 posted\n' >"$STUB_SCENARIO"
  out="$(announce)" || exit 1
  [[ "$out" == "posted" ]] || exit 1
  [[ "$(wc -l <"$STUB_CALLS")" == 1 ]] || exit 1
  [[ ! -s "$STUB_SLEEPS" ]] || exit 1
)
report "200 succeeds on first attempt, no retry" $?

# 2. 429 with Retry-After honored (clamped to >=5), succeeds on attempt 2.
(
  setup
  printf '429 limited 3\n200 posted\n' >"$STUB_SCENARIO"
  out="$(announce)" || exit 1
  [[ "$out" == "posted" ]] || exit 1
  [[ "$(wc -l <"$STUB_CALLS")" == 2 ]] || exit 1
  [[ "$(cat "$STUB_SLEEPS")" == "5" ]] || exit 1
)
report "429 retries after clamped Retry-After and succeeds" $?

# 3. PLANTED NEGATIVE: non-retryable 400 fails immediately, exactly one call.
(
  setup
  printf '400 bad\n200 posted\n' >"$STUB_SCENARIO"
  if (announce) >/dev/null 2>&1; then exit 1; fi
  [[ "$(wc -l <"$STUB_CALLS")" == 1 ]] || exit 1
)
report "400 fails immediately without retry (planted negative)" $?

# 4. Persistent 409 exhausts all 5 attempts then fails, sleeping 4 times.
(
  setup
  printf '409 busy 2\n409 busy 2\n409 busy 2\n409 busy 2\n409 busy 2\n' >"$STUB_SCENARIO"
  if (announce) >/dev/null 2>&1; then exit 1; fi
  [[ "$(wc -l <"$STUB_CALLS")" == 5 ]] || exit 1
  [[ "$(wc -l <"$STUB_SLEEPS")" == 4 ]] || exit 1
)
report "persistent 409 exhausts 5 attempts then fails" $?

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
