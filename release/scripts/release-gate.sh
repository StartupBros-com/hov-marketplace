#!/usr/bin/env bash
set -euo pipefail

name="${1:?usage: release-gate.sh <name> <sha>}"; sha="${2:?sha is required}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"; branch="${DEFAULT_BRANCH:-main}"
ci="${CI_WORKFLOW:-plugins-ci.yml}"; required="${REQUIRED_CHECKS:-release/required-checks.tsv}"
plumbing="${PLUMBING_WORKFLOWS:-auto-release.yml release.yml publish-staged-release.yml release-train.yml repin-reconcile.yml validate.yml ci.yml}"
poll="${GATE_POLL_SECS:-30}"; deadline=$((SECONDS + ${GATE_DEADLINE_SECS:-1800}))
fail() { printf '::error::%s\n' "$*" >&2; exit 1; }
[ -f "$required" ] || fail "required checks file $required does not exist"
awk -F '\t' '/^[[:space:]]*(#|$)/ {next}
  NF != 2 || $1 !~ /^[^/[:space:]]+\.yml$/ || $2 !~ /[^[:space:]]/ {bad=1} END {exit bad}' "$required" \
  || fail "invalid workflow file or job in $required; expected two tab-separated fields"
files=("$ci"); jobs=("$name")
while IFS=$'\t' read -r file job || [ -n "$file$job" ]; do
  [[ "$file" =~ ^[[:space:]]*(#|$) ]] && continue
  files+=("$file"); jobs+=("$job")
done <"$required"

while :; do
  waiting=''
  for i in "${!files[@]}"; do
    file="${files[$i]}"; job="${jobs[$i]}"
    # --jq is applied by gh to EACH page. Slurp only the resulting run objects.
    runs="$(gh api --paginate "repos/$repo/actions/workflows/$file/runs?head_sha=$sha&branch=$branch&per_page=50" --jq '.workflow_runs[]')" \
      || fail "cannot read workflow $file runs for $sha on $branch"
    latest="$(jq -sc --arg sha "$sha" --arg branch "$branch" '
      [.[] | select((.event == "push" or .event == "workflow_dispatch")
        and .head_sha == $sha and .head_branch == $branch)] | max_by(.id) // empty' <<<"$runs")" \
      || fail "cannot parse workflow $file runs for $sha on $branch"
    if [ -z "$latest" ]; then
      waiting="no $file run found for $sha on $branch"
    elif [ "$(jq -r .status <<<"$latest")" != completed ]; then
      waiting="$file run $(jq -r .id <<<"$latest") has not completed on $sha"
    else
      id="$(jq -r .id <<<"$latest")"
      objects="$(gh api --paginate "repos/$repo/actions/runs/$id/jobs?per_page=100" --jq '.jobs[]')" \
        || fail "cannot read jobs in $file run $id on $sha"
      check="$(jq -sc --arg job "$job" '[.[] | select(.name == $job)] | max_by(.id) // empty' <<<"$objects")" \
        || fail "cannot parse jobs in $file run $id on $sha"
      if [ -z "$check" ]; then
        hint=''; if [ "$file" = "$ci" ] && [ "$job" = "$name" ]; then hint="; CI runs a plugin's checks only when its paths change"; fi
        fail "job $job did not run in $file run $id on $sha$hint"
      fi
      conclusion="$(jq -r '.conclusion // "none"' <<<"$check")"
      [ "$conclusion" = success ] || fail "job $job in $file run $id concluded $conclusion on $sha"
      printf 'ok - job %s in %s run %s passed on %s\n' "$job" "$file" "$id" "$sha"
    fi
    # Report the particular missing/pending workflow, including at a zero deadline.
    if [ -n "$waiting" ] && [ "$SECONDS" -ge "$deadline" ]; then fail "$waiting"; fi
  done
  if [ -z "$waiting" ]; then break; fi
  printf '::notice::waiting: %s\n' "$waiting"
  sleep "$poll"
done

all="$(gh api --paginate "repos/$repo/actions/runs?head_sha=$sha&per_page=100" --jq '.workflow_runs[]')" \
  || fail "cannot read unregistered workflow runs on $sha"
bad="$(jq -sc '.[] | select(.status == "completed" and (.conclusion == "failure" or .conclusion == "timed_out"))' <<<"$all")" \
  || fail "cannot parse unregistered workflow runs on $sha"
while IFS= read -r run; do
  [ -n "$run" ] || continue
  path="$(jq -r .path <<<"$run")"; file="${path##*/}"
  case " $plumbing ${files[*]} " in *" $file "*) continue ;; esac
  fail "unregistered workflow $path run $(jq -r .id <<<"$run") concluded $(jq -r .conclusion <<<"$run") on $sha; add it to release/required-checks.tsv or to the plumbing list"
done <<<"$bad"
