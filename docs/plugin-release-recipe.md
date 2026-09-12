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

### Provisioning a NEW plugin repository (measured on sign-it, 2026-09-12)

Copying the three workflows is not enough; the release identity has to be able
to see the repository from two separate places, and only the first is scriptable:

1. Org secrets `HOV_RELEASE_APP_ID` and `HOV_RELEASE_APP_PRIVATE_KEY` use
   "selected repositories": add the new repo
   (`gh api -X PUT orgs/StartupBros-com/actions/secrets/<NAME>/repositories/<repo_id>`).
2. The `startupbros-hov-release` GitHub App installation also uses "selected
   repositories". Adding a repo to it through the API returns 403 for anything
   short of an organization owner, so this is a UI step: Organization settings
   → GitHub Apps → startupbros-hov-release → Configure → Repository access →
   add the repository. Until it is done, `auto-release.yml` fails at "Mint a
   release App installation token" with a 404 from the installation lookup,
   even with the secrets in place.

3. `repin-reconcile` only reconciles cards that already exist, and its
   draft-visible read token is minted for the explicit `repositories:` list in
   `.github/workflows/repin-reconcile.yml`. For a NEW plugin, write the first
   card by hand (name, `source.url`, `source.sha` = the commit the release tag
   points at, `metadata.{version,releaseId,releaseTag}`, `card.rows`,
   `card.run`), add the repo to that `repositories:` list, and add the README
   install line and section in the same PR. Later releases reconcile
   automatically.

Bootstrap the repo at a pre-release `VERSION` (for example `0.1.0-rc1`) so the
first push to main does not try to release before both are in place; the real
version bump PR is then the ship signal as described below.

## The order

Since 2026-09 every catalog plugin carries three identical workflows (pattern
from pro-gate, generalized in hov-marketplace#118): `auto-release.yml`,
`release.yml` and `publish-staged-release.yml`. With them, a release is:

1. Land the version bump in the plugin repo **through a PR**: VERSION and
   `.claude-plugin/plugin.json` move together (the CI contract rejects a
   mismatch), and `docs/release-notes/vX.Y.Z.md` carries a `## Highlights`
   section. Merging is the ship signal.
2. `auto-release.yml` sees an untagged VERSION on `main` and pushes `vX.Y.Z`
   at the merged head as the release App (see Release identity below). Squash merges change
   the sha, so the tag goes at the merged head, never at a local commit.
3. `release.yml` requires the tag on `main`, equal to VERSION, on a commit
   whose CI runs are green, then stages a **draft** release titled
   `<plugin> vX.Y.Z` from the notes file (auto-notes with a warning if the
   file is missing or has no usable Highlights).
4. `repin-reconcile` here sees the draft within the hour and opens the card
   PR (version, tag, releaseId, sha). Review and merge it; the validator
   resolves the tag to the pinned commit.
5. Dispatch `Publish staged release` in the plugin repo with the tag. It
   refuses until the live card names that exact release, then flips the
   draft to published with `--latest`. The single publish event announces.
6. Verify the `#tool-drops` message from the exact run log, not the
   workflow's conclusion (a not-listed skip also reports success):

   ```bash
   gh run list --repo StartupBros-com/<plugin> --workflow "Release train" --limit 8 \
     --json databaseId,status,displayTitle,createdAt \
     --jq '.[] | select(.displayTitle=="<plugin> v<version>") | "\(.databaseId) \(.status) \(.createdAt)"'
   gh run view <run-id> --repo StartupBros-com/<plugin> --log \
     | grep -E '"status":"announced"|does not yet list'
   ```

   Select the run by its display title and a creation time after the publish
   (never "newest completed": that printed the previous release's receipt once),
   and inline the title in the filter: the GitHub CLI's `--jq` takes no `--arg`,
   and a retry loop around that error runs forever.

   `{"status":"announced","messageId":"…"}` is the terminal proof. A
   `does not yet list` notice means no post happened, even when GitHub paints
   the run green. Repeated edits may return the same message ID because the
   service updates the existing card instead of posting a duplicate.

Two steps stay human on purpose: merging the card PR, because a standing
credential that writes this manifest unattended is the one whose compromise
reaches every installed client; and dispatching the publish, because it fires
the outward announce and auto-dispatching a privileged publish from another
repository is how release loops start.

### Release identity

The tag push and the publish must come from an identity whose events trigger
workflows; `GITHUB_TOKEN` events are suppressed by GitHub's recursion rule, so
a tag or publish made with it leaves `release.yml` and the release train dead.
The identity is the GitHub App **StartupBros HOV Release**: contents write
only, installed on the catalog plugin repositories only, and minted per run as
a short-lived installation token scoped to the current repository. Its
credentials are the organization Actions secrets `HOV_RELEASE_APP_ID` and
`HOV_RELEASE_APP_PRIVATE_KEY`, visible to the plugin repositories only. A
`RELEASE_PAT` repository secret still works as a fallback (pro-gate's original
shape). Adding a new plugin to the catalog means adding its repository to the
App installation, to both secrets' repository lists, and to the `repositories:`
list in this repo's `repin-reconcile.yml`.

The card PR is opened by a second App, **StartupBros HOV Marketplace Bot**:
contents and pull-request write on this repository only, never merge, secrets
`HOV_MARKETPLACE_APP_ID` and `HOV_MARKETPLACE_APP_PRIVATE_KEY` visible to this
repository only. Two facts force the split: GitHub shows another repository's
draft releases only to push-capable identities, so the reconciler reads with a
release-App token; and this organization keeps GitHub's default that forbids
`GITHUB_TOKEN` from creating pull requests, so the PR needs an App identity of
its own (an App-opened PR also runs the validator without the approval gate a
`GITHUB_TOKEN`-opened PR sits behind). Without the bot secrets the reconciler
still pushes the repin branch and names the PR to open by hand.

Without either identity, `auto-release.yml` skips with a notice naming the tag
to push, and the manual flow is unchanged: push `vX.Y.Z` at the merged main
sha yourself, dispatch `release.yml` with the tag (or run `gh release create
vX.Y.Z --draft --verify-tag --title "<plugin> vX.Y.Z" --notes-file
docs/release-notes/vX.Y.Z.md`), wait for or merge the reconciler's card PR,
then publish from your own identity with `gh release edit vX.Y.Z
--draft=false --latest`; `publish-staged-release.yml` refuses without an
identity for the reason above. Branch names must never be tag-shaped
(`vX.Y.Z` as a branch collides with the tag in `actions/checkout` ref
resolution — issue #49).

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
