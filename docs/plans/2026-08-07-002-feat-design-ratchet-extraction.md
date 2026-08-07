# design-ratchet: extract the design-drift engine into an OSS plugin

Plan only — no implementation in this PR. Follows the plan-PR convention set by
`2026-08-07-001-feat-skill-tuner-plan.md`. Two decisions in here are Will-owned
and explicitly gate later phases; everything else is agent-executable.

## Premise verification (2026-08-07 recon, workflow wf_ac033f66)

Every claim below was verified by running commands, not recalled:

- **dotfiles origin/main has NOT moved** — it is exactly `34a10ae2` (the #265
  merge), confirmed via local fetch and independently via GitHub API. The
  "moved significantly" impression came from two real-but-different things:
  the launch checkout's local `main` ref is 7 commits stale, and pushbot moved
  +9 commits (none touching `design/` or the vendored scanner; ratchet green).
- **The engine is validated**: 4/4 public-repo agreement with each repo's own
  declared tokens (taxonomy, cal.com, excalidraw, outline), 62/62 tests with
  verified mutation kills, drift numbers byte-identical through the #264
  change. This is the README evidence base.
- **skill-tuner is NOT a skill publisher** — it is an authoring-doctrine
  plugin, itself mid-flight to this marketplace (plan PR #7, public flip
  pending). No rail to ride; design-ratchet follows the same runbook instead
  (public-flip evidence precedent: merged PR #3). Incidental receipt:
  design-drift's SKILL.md scored cleanest of the six documents skill-tuner's
  eval audited (0 confirmed defects).
- **Marketplace model unchanged**: `.claude-plugin/marketplace.json`, plugins
  as external repos pinned URL+SHA+releaseTag, promotion commits
  `chore: promote <plugin> v<version>`, CI validates pinned sources
  (`HOV_SOURCES_PUBLIC` on — a private/untagged source cannot go green).
- **Upstream @google/design.md is stationary at 0.4.0** (zero commits since
  Jul 27; all four documented CLI traps re-verified live at HEAD), but PR
  traffic resumed 2026-08-07 (shadows/elevation, physical units, four stale
  a11y-lint PRs incl. min-lineHeight). Pin 0.4.0; re-probe on any release.
- **Naming is contested**: npm `design-drift` is an ACTIVE adjacent tool
  (Figma-vs-shipped pixel diff, updated 2026-08-02). Launching under the same
  name in the same niche is a mindshare collision, not just a namespace one.
  `design-ratchet` is free on npm with no meaningful GitHub collisions.
- **Live deploy is stale on both targets** (~/.claude and ~/.codex both at
  Aug 6, missing all five of today's design-drift merges), and
  `skills-localize.sh` must run in place from the dotfiles checkout — a /tmp
  copy no-ops SILENTLY ("done", zero drift lines) because its path-derived
  roots vanish and every loop is `[ -d ] || return 0` guarded.

## Will-owned gates (everything else proceeds without them)

1. **G1 — Name.** Recommendation: repo `StartupBros-com/design-ratchet`, npm
   `design-ratchet`, binary `design-ratchet`. The harness-internal skill can
   keep its `design-drift` name (no forced rename). Alternatives: scoped
   `@startupbros/design-drift` (accepts the mindshare collision), `driftlint`
   (npm free; three zero-star GitHub squats).
2. **G2 — Public flip + v0.1.0 tag.** Same runbook as skill-tuner/PR #3:
   repo goes public and gets a `v0.1.0` tag at the pinned SHA. Marketplace
   promotion cannot go green before this.

## Architecture decisions

- **D1 — Canonical home moves to the new repo.** Community PRs, issues and
  releases happen upstream; dotfiles becomes a consumer. The alternative
  (dotfiles-canonical with a filtered public mirror) doubles every review
  surface and makes outside contribution second-class. Rationale precedent:
  the vendoring note in prbot's PROVENANCE.md gives "dotfiles is private" as
  the only reason vendoring exists — a public canonical repo deletes that
  reason.
- **D2 — dotfiles consumes via the existing localize machinery.** The engine
  scripts become a pinned vendor drop into `claude/skills-local/design-drift/`
  (SHA-stamped PROVENANCE, exactly like the emil-skills frozen-snapshot
  pattern), and the harness-specific workflow prose (ce-plan handoff,
  wt-new.sh, CE DESIGN.md-collision note, review-ladder wiring) moves to the
  overlay layer (`skills-patches/` pattern, already proven). Public SKILL.md
  stays generic.
- **D3 — prbot switches from vendored file to pinned package.** CI runs
  `npx design-ratchet@0.1.0 scan . --fail-on=…` instead of the vendored copy;
  the tooling/scripts/design-drift/ directory and its manual re-sync ritual
  are deleted. One prbot PR, after G2.
- **D4 — Fresh history, curated import.** The new repo starts from a clean
  commit of the current engine, not a filter-repo of dotfiles history.
  Private-repo history carries session/infra context that has no business in
  public git archaeology; PROVENANCE.md carries the lineage instead.
- **D5 — Ship both halves, position the scanner first.** Post-#264 the
  proposer earned its place (4/4 declared-truth agreement), but the README
  leads with measure/enforce (the uncontested value) and frames propose as
  "derive a starting system, then review" with the two-tier provenance story.
- **D6 — v0.2 roadmap lives upstream.** Issue #261 (region budgets +
  tighten/bump) migrates to the new repo as its first milestone — it is a
  community-facing feature, and building it post-extraction avoids blocking
  launch. rgba()/hsl() clustering and dark-mode modelling join it.

## Repo layout (v0.1.0)

```
design-ratchet/
  bin/design-ratchet          # thin dispatcher: scan | propose | (v0.2: tighten/bump)
  src/scan.mjs                # engine, dependency-free (from dotfiles @34a10ae2)
  src/propose.mjs
  test/scan.test.mjs          # 62 tests, mutation-check notes preserved in comments
  test/propose.test.mjs
  skills/design-ratchet/SKILL.md   # generic skill (Claude Code plugin surface)
  .claude-plugin/plugin.json
  docs/validation.md          # the 4-repo evidence table + method
  docs/upstream-limits.md     # the four @google/design.md v0.4.0 traps, dated
  PROVENANCE.md               # lineage + method credits
  LICENSE (MIT) + NOTICE      # plugin87 (MIT ideas), impeccable (Apache-2.0
                              # method), design-system-ops (MIT method)
  .github/workflows/ci.yml    # hosted runners (public repo: free minutes;
                              # the $0-Actions-limit constraint is private-only)
```

## Phases

- **P0 — hygiene (dotfiles/prbot, no gates).** prbot vendored scan.mjs
  re-sync to 34a10ae2 (no ratchet impact: declaredTokens is --full-only;
  budgets already have slack at 2395/24 actual vs 2396/25 budget — tighten in
  the same PR). Operator runs skills-localize apply in place (both ~/.claude
  and ~/.codex close five merges of drift; command in the PR body).
- **P1 — scaffold (after G1, repo created PRIVATE).** Curated import, private-
  identifier sweep (checklist: prbot, pushbot, formal-founder,
  startupbros-funnels — the #264/#265 commits added fresh mentions in
  comments), README with validation evidence, CI green, `designmd lint`
  smoke-test pinned to @google/design.md@0.4.0.
- **P2 — consumption switch (dotfiles).** Vendor drop + overlay split per D2;
  skills-localize deploys it; harness behaviour unchanged (same engine bytes).
- **P3 — G2 flip + release.** Will flips public, tags v0.1.0. Record flip
  evidence per PR #3 precedent.
- **P4 — marketplace + prbot.** `chore: promote design-ratchet v0.1.0` entry
  (URL+SHA+releaseTag); prbot CI switch per D3; migrate #261 upstream.

Each phase is one PR-sized unit with its own work-spec (Acceptance Criteria /
Planted negative / No-Claim Boundary) written at execution time — this plan
deliberately does not pre-write them, since P1's criteria depend on G1.

## Planted negatives for the plan itself

- A P1 that imports dotfiles git history instead of a curated snapshot fails
  D4 (leaks private context into public archaeology).
- A P2 that edits engine bytes during the split violates "same engine bytes"
  — the consumption switch must be a provenance change, not a code change.
- A marketplace entry before G2 cannot go green (HOV_SOURCES_PUBLIC) — do not
  burn a promotion commit on it.

## No-Claim Boundary

- No adoption claim: shipping the plugin proves availability, not usage.
- The 4-repo validation generalizes the extractor across paradigms; it says
  nothing about repos with no styling at all, non-web UI, or CSS-in-JS
  template literals (documented v0.2 gap).
- Upstream 0.4.0 pinning is a snapshot: the four traps are re-verified as of
  2026-08-07 and decay on the next upstream release.
