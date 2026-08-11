# Plugin release recipe (draft-first)

The bump ordering has a built-in race: the marketplace card needs the
`releaseId` (born when the release is created), while the announce guard needs
the merged card. Creating a published release first means its announce run
races the card merge — on 2026-08-11 (harness-vet v0.1.2) the publish-event
run lost that race by seconds and skipped, and the recovery re-fires collided
with the announce service's global verification gate (issue #56). Draft-first
dissolves the race: a draft release has an id but fires no announce.

## The order

1. Merge the version bump in the plugin repo; note the main sha.
2. `gh release create vX.Y.Z --repo StartupBros-com/<plugin> --target main --draft --title "<plugin> vX.Y.Z" --notes "..."` — the draft's id is the
   `releaseId` for the card. Branch names must never be tag-shaped
   (`vX.Y.Z` as a branch collides with the tag in `actions/checkout` ref
   resolution — issue #49).
3. Marketplace PR: card `sha` = the plugin main sha, `version`, `releaseId`
   (from the draft), `releaseTag` = `vX.Y.Z`. Merge it, validator green.
4. Publish the draft (`gh release edit vX.Y.Z --draft=false`). The single
   publish-event announce finds the card current — no re-fire needed.
5. Verify the #tool-drops message by its timestamp, not the workflow's
   conclusion (a not-listed skip also reports success).

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
  minutes collide. Space releases, or let the announce script's retry (added
  with this doc; honors `Retry-After`, clamped 5-600s, 5 attempts) outlast
  the window.
- **409** — a processing lease or residual cooldown is held
  (`Retry-After: 2` accompanies it); the retry handles this too.
- Non-retryable statuses (400/401/403) fail immediately by design.
