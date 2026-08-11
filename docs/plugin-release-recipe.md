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
