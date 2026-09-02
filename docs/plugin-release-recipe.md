# Plugin release recipe (draft-first)

The bump ordering has a built-in race: the marketplace card needs the
`releaseId` (born when the release is created), while the announce guard needs
the merged card. Creating a published release first means its announce run
races the card merge — on 2026-08-11 (harness-vet v0.1.2) the publish-event
run lost that race by seconds and skipped, and the recovery re-fires collided
with the announce service's global verification gate (issue #56). Draft-first
dissolves the race: a draft release has an id but fires no announce.

## Before adding a NEW plugin to the catalog

Growing the catalog has a measured cost outside Claude Code. Verified live on
2026-08-10 with Codex v0.147.0: `codex plugin marketplace add
StartupBros-com/hov-marketplace` reads this manifest unchanged and installs from
it, so the catalog is cross-agent installable at no extra cost. But Codex warns
`Exceeded skills context budget. All skill descriptions were removed` on
plugin-heavy installs, and that silently disables model-invoked routing there.

The binding constraint is the **number of skills and the length of their
descriptions**, not the number of repos — consolidating repos does not buy
headroom, trimming descriptions does. Before adding plugin N+1, either re-check
a Codex install or accept that the one distribution lane already proven to work
outside Claude Code degrades a little further. Keep descriptions lean.

## The order

1. Land the version bump in the plugin repo **through a PR**, then note the
   MERGED main sha. A repo with a required-checks ruleset declines a direct
   push to main outright (papercut gained `require-ci` on 2026-09-01; the
   v0.1.8 push was refused with GH013 after tests, vendor and bump had
   already run), and a squash merge changes the sha — so the tag goes at
   the merged head, never at the local release commit. Push `vX.Y.Z` as a
   tag at that sha before the card validates: a draft mints no tag ref and
   `validate-marketplace.sh` requires one that resolves to the pinned commit.
2. `gh release create vX.Y.Z --repo StartupBros-com/<plugin> --target main --draft --title "<plugin> vX.Y.Z" --notes "..."` — the draft's id is the
   `releaseId` for the card. Branch names must never be tag-shaped
   (`vX.Y.Z` as a branch collides with the tag in `actions/checkout` ref
   resolution — issue #49).
3. Marketplace PR: card `sha` = the plugin main sha, `version`, `releaseId`
   (from the draft), `releaseTag` = `vX.Y.Z`. Merge it, validator green.
4. Publish the draft (`gh release edit vX.Y.Z --draft=false`). The single
   publish-event announce finds the card current — no re-fire needed.
5. Verify the `#tool-drops` message from the exact run log, not the workflow's
   conclusion (a not-listed skip also reports success):

   ```bash
   gh run view <run-id> --repo StartupBros-com/<plugin> --log \
     | grep -E '"status":"announced"|does not yet list'
   ```

   `{"status":"announced","messageId":"…"}` is the terminal proof. A
   `does not yet list` notice means no post happened, even when GitHub paints
   the run green. Repeated edits may return the same message ID because the
   service updates the existing card instead of posting a duplicate.

## Release notes: lead with `## Highlights`

The drop card's what's-new block is derived from the release body, in this
order: an author-written `## Highlights` section's bullets → GitHub's auto
"What's Changed" bullets → the first paragraph as prose. Only the first
produces a clean 3-bullet card; the prose fallback reads as a wall of text
and now emits a CI warning (audited 2026-08-11: 5 of 8 plugins' latest
releases were on the fallback path).

```markdown
## Highlights

- What changed, in the reader's terms — the capability, not the commit.
- One line per change worth a user's attention; at most three reach the card.
- Detail, incidents, and receipts go below this section (they are kept in
  the release, just not on the card).
```

Rules that make the bullets land: user-facing outcome first (the extractor
strips `feat:`/`fix:` prefixes and trailing `by @author in <url>`, so
changelog-style bullets survive but read poorly); ≤180 characters each; and
if a release genuinely has no user-visible change, say so in one bullet
rather than leaving the section out.

## Announce service error semantics (issue #56)

- **429 "GitHub release verification is rate limited"** — the service holds a
  global 600-second verification gate per channel
  (`OIDC_PREFLIGHT_LEASE_SECONDS`); any two plugin releases inside ~10
  minutes collide. Space releases, or let the announce script honor the
  service's canonical `Retry-After` value.
- **409** — a processing lease or residual cooldown is held; a canonical
  `Retry-After` authorizes the same bounded retry path.
- The announce helper allows exactly eight attempts. Each attempt mints a new
  body-bound OIDC token, preserves the exact request bytes, and sleeps for the
  server delay plus a two-second lease cushion and deterministic 0–3 second
  jitter. There is no ninth mint, POST, or sleep.
- Only 409 and 429 retry. Missing, duplicate, folded, date-form, zero,
  leading-zero, or out-of-range `Retry-After` values fail closed. Transport
  failures, redirects, 5xx responses, and other statuses do not retry.
