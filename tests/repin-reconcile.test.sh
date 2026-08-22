#!/usr/bin/env bash
set -euo pipefail

# Tests for scripts/repin-reconcile.sh.
#
# The reconciler's whole value is that it is safe to run repeatedly, so the two
# properties worth proving are: it converges on the released state, and running
# it again from that state does nothing at all — including no formatting churn,
# which would otherwise rewrite every plugin's card and bury the real change.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0

pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
die() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

mkdir -p "$TMP/bin"

# Stub gh: serves release/tag/repo metadata for one fake plugin from fixtures.
# It honours --jq, because the script relies on gh applying that filter; a stub
# that ignored it would hand back raw JSON and test a shape production never sees.
write_gh_stub() { # $1 = compare status to report
  cat > "$TMP/bin/gh" <<STUBGH
#!/usr/bin/env bash
set -e
path="\$2"; shift 2
jqexpr=""
while [ \$# -gt 0 ]; do
  case "\$1" in --jq) jqexpr="\$2"; shift 2 ;; *) shift ;; esac
done
emit() { if [ -n "\$jqexpr" ]; then jq -r "\$jqexpr"; else cat; fi; }
case "\$path" in
  repos/acme/widget/releases*) emit < "\$FIX/releases.json" ;;
  repos/acme/widget/git/ref/tags/*) emit < "\$FIX/tagref.json" ;;
  repos/acme/widget/compare/*) printf '{"status":"$1"}\n' | emit ;;
  repos/acme/widget) printf '{"default_branch":"main"}\n' | emit ;;
  *) printf 'unexpected gh api: %s\n' "\$path" >&2; exit 1 ;;
esac
STUBGH
  chmod +x "$TMP/bin/gh"
}
write_gh_stub identical

export FIX="$TMP/fix"
mkdir -p "$FIX"

NEW_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

printf '[{"id":900,"tag_name":"v2.0.0","draft":false,"prerelease":false,"created_at":"2026-08-20T00:00:00Z"},{"id":800,"tag_name":"v1.0.0","draft":false,"prerelease":false,"created_at":"2026-08-01T00:00:00Z"}]\n' > "$FIX/releases.json"
printf '{"object":{"sha":"%s","type":"commit"}}\n' "$NEW_SHA" > "$FIX/tagref.json"

make_manifest() { # $1 = version, $2 = tag, $3 = id, $4 = sha, $5 = dest
  jq -a --indent 2 -n \
    --arg v "$1" --arg t "$2" --argjson i "$3" --arg s "$4" '
    {plugins: [{
      name: "widget",
      source: {source: "url", url: "https://github.com/acme/widget.git", sha: $s},
      description: "unicode check — an em dash and ⚡ a bolt",
      metadata: {version: $v, releaseId: $i, releaseTag: $t},
      card: {rows: ["⚡ one", "🛡️ two"], run: "go"}
    }]}' > "$5"
}

run_reconcile() { # $1 = manifest path
  PATH="$TMP/bin:$PATH" FIX="$FIX" MANIFEST="$1" PLAN_FILE="$TMP/plan.tsv" \
    bash "$ROOT/scripts/repin-reconcile.sh" 2>"$TMP/err"
}

# --- converges on the released state -----------------------------------------
make_manifest '1.0.0' 'v1.0.0' 800 "$OLD_SHA" "$TMP/stale.json"
run_reconcile "$TMP/stale.json" >"$TMP/out" || die 'reconciler failed on a stale manifest'
grep -q 'repinned 1' "$TMP/out" || die 'stale manifest was not reported as repinned'
pass 'a stale card is repinned to the newest release'

got="$(jq -r '.plugins[0] | "\(.metadata.version) \(.metadata.releaseTag) \(.metadata.releaseId) \(.source.sha)"' "$TMP/stale.json")"
[ "$got" = "2.0.0 v2.0.0 900 $NEW_SHA" ] || die "repinned tuple is wrong: $got"
pass 'the repinned tuple matches the newest release exactly'

# --- idempotent: a second run changes nothing --------------------------------
cp "$TMP/stale.json" "$TMP/after-first.json"
run_reconcile "$TMP/stale.json" >"$TMP/out2" || die 'second run failed'
grep -q 'already matches' "$TMP/out2" || die 'second run did not report convergence'
pass 'a second run reports the manifest already matches'

diff -q "$TMP/after-first.json" "$TMP/stale.json" >/dev/null \
  || die 'second run modified an already-current manifest'
pass 'a second run leaves the manifest byte-identical'

# --- no formatting churn ------------------------------------------------------
# The card carries \uXXXX escapes. A jq round-trip that drops -a would rewrite
# every one of them, producing a diff across cards nobody touched.
grep -q '\\u26a1' "$TMP/stale.json" || die 'unicode escapes were rewritten by the reconciler'
pass 'unicode escaping in untouched cards is preserved'

# --- a current manifest is left completely alone ------------------------------
make_manifest '2.0.0' 'v2.0.0' 900 "$NEW_SHA" "$TMP/current.json"
cp "$TMP/current.json" "$TMP/current.orig.json"
run_reconcile "$TMP/current.json" >"$TMP/out3" || die 'reconciler failed on a current manifest'
diff -q "$TMP/current.orig.json" "$TMP/current.json" >/dev/null \
  || die 'a current manifest was modified'
[ ! -f "$TMP/plan.tsv" ] || die 'a plan file was left behind with no drift'
pass 'a current manifest is untouched and leaves no plan file'

# --- dry run never writes -----------------------------------------------------
make_manifest '1.0.0' 'v1.0.0' 800 "$OLD_SHA" "$TMP/dry.json"
cp "$TMP/dry.json" "$TMP/dry.orig.json"
PATH="$TMP/bin:$PATH" FIX="$FIX" MANIFEST="$TMP/dry.json" PLAN_FILE="$TMP/plan.tsv" DRY_RUN=1 \
  bash "$ROOT/scripts/repin-reconcile.sh" >"$TMP/out4" 2>&1 || die 'dry run failed'
diff -q "$TMP/dry.orig.json" "$TMP/dry.json" >/dev/null || die 'dry run modified the manifest'
grep -q 'dry run' "$TMP/out4" || die 'dry run did not say so'
pass 'DRY_RUN reports drift without writing'

# --- a tag off the default branch is never pinned -----------------------------
write_gh_stub diverged
make_manifest '1.0.0' 'v1.0.0' 800 "$OLD_SHA" "$TMP/side.json"
cp "$TMP/side.json" "$TMP/side.orig.json"
run_reconcile "$TMP/side.json" >"$TMP/out5" || die 'reconciler failed on a diverged tag'
diff -q "$TMP/side.orig.json" "$TMP/side.json" >/dev/null \
  || die 'a tag off the default branch was pinned into the manifest'
pass 'a tag that is not on the default branch is never pinned'

printf '%s repin reconcile checks passed\n' "$PASS"
