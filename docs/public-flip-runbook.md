# Public flip and release train runbook

## Ownership and stop conditions

Will owns every command marked **Will-owned**. Automation must not change repository visibility, mint credentials, enable organization security settings, apply the production migration, publish releases, move staged vault pages live, or send the Discord reply.

Stop immediately if:

- Any full-history secrets scan reports a finding.
- Any repository contains an unexpected issue, pull request, discussion, release asset, or author email that should not become public.
- The unauthenticated install smoke returns an authentication prompt, 404, checksum error, version mismatch, or duplicate skill or agent.
- Marketplace validation, the announcement test fire, or any release workflow fails.

The accepted secrets-history contingency is a clean-history republish. Preserve required source and release artifacts, publish from a new clean root, rerun every scan, then resume only after all three scans are clean.

## Completed evidence

### Secrets-history gate

Status: **CLEAR as of 2026-07-13**.

Gitleaks 8.28.0 scanned every commit and ref available in each clone.

| Repository | Scanned commit | Result |
| --- | --- | --- |
| `StartupBros-com/token-eater` | `05af296dd0e411ed72b6cd69437e10f027c8066b` | Clean, 0 findings |
| `StartupBros-com/pro-gate` | `841baf839bf701a81e8e7cce6b53f380758aedb7` | Clean, 0 findings |
| `StartupBros-com/hov-marketplace` | `05619ca07d043e2b711c98915168f0fcd914c743` | Clean, 0 findings |

Reproduce after fetching every ref:

```bash
git fetch --all --tags --prune
gitleaks git . --log-opts="--all" --redact=100
```

A finding blocks all visibility changes.

### Local release-train smoke

Completed on 2026-07-14 for token-eater and pro-gate using local bare Git remotes and a stubbed announce endpoint. Both harnesses proved:

- Latest stable release advances only its own marketplace entry.
- The announcement operation is called after promotion.
- A rerun does not create another marketplace commit and calls the idempotent announcement operation again.
- An older release cannot roll the marketplace backward and does not announce.
- A prerelease does not mutate the production marketplace or announce.
- An edited release calls the announcement operation without marketplace mutation.
- A failed non-fast-forward push retains the local promotion commit for bounded retry.

Commands:

```bash
bash tests/release-train.test.sh
```

Run once in each tool repository.

## Pre-flip setup

### 1. Land the implementation PRs

Merge in dependency order:

1. prbot tool-release announcement route and migration.
2. token-eater consent gate and release train.
3. pro-gate plugin/runtime packaging and release train.
4. hov-marketplace catalog and validator, pinned to the landed tool commits.

Do not move files from `apps/startupbros/content-staging/vault/` into `apps/startupbros/content/vault/` yet.

### 2. Apply the production migration

**Will-owned.** Apply the prbot migration after the prbot code PR is merged and before setting the announce endpoint live:

```bash
cd apps/startupbros
supabase link --project-ref odohsprxbcctfyoldtdr
supabase db push
supabase migration list
```

Verify `20260713140000_create_tool_release_announcements.sql` is applied. Confirm RLS is enabled and only `service_role` has `SELECT`, `INSERT`, and `UPDATE` grants.

### 3. Mint dedicated credentials

**Will-owned.** Create one fine-grained PAT per tool repository. Each PAT must be scoped only to `StartupBros-com/hov-marketplace` with repository `Contents: Read and write`. Do not reuse either PAT between tools.

Create one random announce secret dedicated to the tool-release route. Do not reuse `INTERNAL_SERVICE_SECRET`, `CRON_SECRET`, or another app secret.

Set repository configuration:

```bash
# Run from any authenticated gh shell.
printf '%s' "$TOKEN_EATER_MARKETPLACE_PAT" | gh secret set HOV_MARKETPLACE_PAT --repo StartupBros-com/token-eater
printf '%s' "$PRO_GATE_MARKETPLACE_PAT" | gh secret set HOV_MARKETPLACE_PAT --repo StartupBros-com/pro-gate
printf '%s' "$TOOL_RELEASE_ANNOUNCE_SECRET" | gh secret set TOOL_RELEASE_ANNOUNCE_SECRET --repo StartupBros-com/token-eater
printf '%s' "$TOOL_RELEASE_ANNOUNCE_SECRET" | gh secret set TOOL_RELEASE_ANNOUNCE_SECRET --repo StartupBros-com/pro-gate

gh variable set TOOL_RELEASE_ANNOUNCE_URL --body 'https://www.startupbros.com/api/internal/ops/tool-releases' --repo StartupBros-com/token-eater
gh variable set TOOL_RELEASE_ANNOUNCE_URL --body 'https://www.startupbros.com/api/internal/ops/tool-releases' --repo StartupBros-com/pro-gate

# Keep syntax validation until all three repositories are public.
gh variable set HOV_MARKETPLACE_VALIDATION_MODE --body syntax --repo StartupBros-com/token-eater
gh variable set HOV_MARKETPLACE_VALIDATION_MODE --body syntax --repo StartupBros-com/pro-gate
```

Set `TOOL_RELEASE_ANNOUNCE_SECRET` in the StartupBros production deployment environment to the same dedicated value, then redeploy the app. Confirm `DISCORD_CHANNEL_ANNOUNCEMENTS_ID` is configured. For the first smoke only, use the test announcements channel override supported by the deployment environment.

### 4. Organization and repository audit

**Will-owned.** Before changing visibility:

- Enable the StartupBros-com organization 2FA requirement.
- Enable GitHub native secret scanning and push protection for each repository where the plan permits it.
- Review every open and closed issue, pull request, discussion, release, wiki page, and Actions artifact for private content.
- Review Git author emails across all history:

```bash
git log --all --format='%ae%n%ce' | sort -u
```

- Rerun gitleaks after the final implementation merges.
- Confirm LICENSE files exist in token-eater and hov-marketplace, and pro-gate retains its license.
- Confirm tracked trees contain no operator-specific paths:

```bash
git grep -nE '(/home/will|home/will|Users/will)' -- .
```

Expected result for the tool repositories: no matches.

## Quiet visibility flip

**Will-owned.** Proceed only when the audit and final scans are clean. Do not announce the flip yet.

```bash
gh repo edit StartupBros-com/token-eater --visibility public --accept-visibility-change-consequences
gh repo edit StartupBros-com/pro-gate --visibility public --accept-visibility-change-consequences
gh repo edit StartupBros-com/hov-marketplace --visibility public --accept-visibility-change-consequences

gh repo view StartupBros-com/token-eater --json visibility,url
gh repo view StartupBros-com/pro-gate --json visibility,url
gh repo view StartupBros-com/hov-marketplace --json visibility,url
```

All three responses must report `PUBLIC`.

Immediately switch both train validators and hov-marketplace CI to full public-source validation:

```bash
gh variable set HOV_MARKETPLACE_VALIDATION_MODE --body full --repo StartupBros-com/token-eater
gh variable set HOV_MARKETPLACE_VALIDATION_MODE --body full --repo StartupBros-com/pro-gate
gh variable set HOV_SOURCES_PUBLIC --body true --repo StartupBros-com/hov-marketplace
```

Trigger hov-marketplace validation on `main` and require the `Pinned sources` job to pass.

## Unauthenticated customer install smoke

Run from a clean machine or clean OS user with no GitHub credentials. Do not rely on a credential helper, SSH key, existing marketplace cache, or development symlink.

In Claude Code:

```text
/plugin marketplace add https://github.com/StartupBros-com/hov-marketplace.git
/plugin install token-eater@hov
/plugin install pro-gate@hov
```

Open `/plugin`, choose **Marketplaces**, select `hov`, and choose **Enable auto-update**.

Verify token-eater:

1. Invoke `/token-eater` in a trusted disposable repository.
2. Confirm the unsandboxed target-repository shell disclosure appears before any repository command.
3. Decline once and confirm no command runs.
4. Accept, rerun, and confirm the same caveat version does not ask again.

Verify pro-gate:

1. Invoke `/pro-gate` with no runtime installed.
2. Confirm it routes to the exact promoted release installer.
3. Confirm checksum verification succeeds and doctor reports matching plugin/runtime versions.
4. Confirm no duplicate skill or agent exists in user-global Claude directories.
5. Confirm the daemon is off.
6. Confirm daemon enablement fails before the versioned dangerous-mode disclosure is accepted.

A 404, authentication prompt, duplicate installation, or version mismatch stops rollout.

## Publish the member vault pages

Only after the unauthenticated smoke is green, move the staged pages into the synced vault tree on a prbot branch:

```bash
git mv apps/startupbros/content-staging/vault/pro-gate.md apps/startupbros/content/vault/pro-gate.md
git mv apps/startupbros/content-staging/vault/token-eater.md apps/startupbros/content/vault/token-eater.md
pnpm --filter startupbros typecheck
pnpm --filter startupbros lint
```

Open and merge the content PR, wait for deployment and content-sync CI, then verify both pages render for an entitled House of Vibe member. This move is the atomic publication step. Never publish either page before the public smoke.

## Announcement endpoint test fire

Before the first real stable release, call the deployed route using a synthetic release ID and the test announcements channel:

```bash
curl --fail-with-body \
  -H 'content-type: application/json' \
  -H "x-tool-release-announce-secret: $TOOL_RELEASE_ANNOUNCE_SECRET" \
  --data '{
    "operation":"announce",
    "repository":"token-eater",
    "releaseId":"900000000000000001",
    "tag":"v0.1.1",
    "releaseName":"Tool Drop test",
    "releaseUrl":"https://github.com/StartupBros-com/token-eater/releases/tag/v0.1.1",
    "notesSummary":"Release train test fire"
  }' \
  https://www.startupbros.com/api/internal/ops/tool-releases
```

Run the same request again. Confirm exactly one Discord message exists and the second request edits that message. Remove or archive the test message using the normal Discord edit-in-place convention, not delete and repost.

## Stable release proof

For each tool, publish a new stable release newer than the currently promoted marker. This is **Will-owned** and must happen only after the corresponding release assets and notes are ready.

For pro-gate, confirm the release includes:

- `pro-gate-runtime-<version>.tar.gz`
- `pro-gate-runtime-<version>.tar.gz.sha256`

Watch the workflow:

```bash
gh run list --workflow release-train.yml --repo StartupBros-com/token-eater --limit 5
gh run list --workflow release-train.yml --repo StartupBros-com/pro-gate --limit 5
gh run watch <run-id> --repo StartupBros-com/<tool>
```

For each tool record:

- GitHub release ID, tag, and commit SHA.
- Marketplace commit and updated entry metadata.
- Workflow run URL.
- Discord channel and message ID.
- Rerun result proving the same marketplace marker and same Discord message.
- Older-release rerun proving no rollback.

If a workflow fails, inspect it and rerun the same workflow. Do not manually edit the marketplace pin. The release event remains the sole promotion act.

## Stale lease recovery

A failed delivery row is reclaimed automatically. A `claimed` row is reclaimable after its lease expires. Rerun the release workflow after the lease expiry. The worker reconciles the deterministic hidden release marker before sending, so an uncertain prior send is adopted rather than duplicated.

Do not mutate the ledger manually unless automatic reclaim is impossible and the root cause is understood. If manual recovery is required, capture the row, Discord message state, and workflow run first. Any lease-token update must preserve fencing and must never let an expired worker finalize over a newer claim.

## Close the promise loop

**Will-owned.** After the public smoke and vault deployment are green, reply to Cooper in `#general` with the working vault path and the two install commands. Ask him to confirm installation succeeds without GitHub credentials. Record the confirmation link here.

- Cooper confirmation: `PENDING`

Do not announce the repository visibility change itself. The member-facing event is the working tool drop.

## Customer-zero soak and member update proof

**Will-owned.** On Will's machines:

1. Remove user-global duplicate skill or agent copies left by manual installs.
2. Install both tools through `hov` marketplace commands.
3. Enable marketplace auto-update.
4. Keep development symlinks only in explicit development environments.
5. Use the marketplace installations for seven consecutive days.

Record:

- Soak start: `PENDING`
- Soak end: `PENDING`
- Machines checked: `PENDING`
- First stable update tag: `PENDING`

For AE3 and R17, observe Cooper or the first engaged member after the next stable release. On their next Claude Code session, confirm the new plugin version is active without a manual update request.

- Member: `PENDING`
- Prior version: `PENDING`
- Updated version: `PENDING`
- Evidence link or timestamp: `PENDING`

## Rollback and failure handling

- Code or workflow defect: revert the responsible merge commit, fix forward in a new release, and never move a marketplace release marker backward.
- Announcement defect: edit the existing Discord message. Never delete and repost.
- Public-source exposure concern discovered after flip: stop release publication and member messaging, preserve evidence, and let Will decide whether to make the affected repository private while remediation is prepared.
- Vault smoke failure: leave staged pages unpublished or revert the content-only publication commit. Do not add access infrastructure or private clone instructions.
- Credential exposure: revoke only the affected tool-scoped PAT or dedicated announce secret, rotate it, then rerun the same release workflow.

## Final evidence checklist

- [x] Initial full-history gitleaks scans clean and recorded.
- [x] Local deterministic release-train smoke passes for both tools.
- [x] Consent first-run, repeat-run, version-bump, and pre-seeded-file tests pass.
- [x] Marketplace validator fixtures pass.
- [x] Pro-gate distribution, checksum, consent, mismatch, and daemon-default tests pass.
- [ ] Final post-merge gitleaks scans clean.
- [ ] Production migration applied.
- [ ] Dedicated secrets and per-tool PATs configured.
- [ ] Organization 2FA and repository audit complete.
- [ ] All three repositories public.
- [ ] Full public-source marketplace validation green.
- [ ] Unauthenticated two-tool install smoke green.
- [ ] Vault pages moved from staging, deployed, and content-sync green.
- [ ] Announcement test fire idempotent in the test channel.
- [ ] One stable promotion per tool recorded.
- [ ] Cooper confirms the working path.
- [ ] Seven-day customer-zero soak complete.
- [ ] First unprompted member update confirmed.
