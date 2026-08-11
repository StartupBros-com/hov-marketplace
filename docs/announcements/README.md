# Announcement payloads

Routine version drops post themselves to `#tool-drops` through the OIDC
release train. This directory holds the member-facing `#announcements`
copy, which is deliberately NOT automated.

## The standing roster post is EDITED, never re-posted

`#📣│announcements` already carries one canonical "House of Vibe tools are
live" post (message `1535757382322225153`, authored by BroBot). When the
catalog changes, EDIT that message: an edit does not re-ping members, and
it keeps one post that is always true instead of two that disagree about
how many tools exist. Re-announcing the same roster is notification spam.

`suite-roster-embeds.json` is the current live body (lede + three themed
embeds, one field per tool). Snapshot the live message before editing, so
a concurrent change is never clobbered and there is always a rollback:

```bash
BOT_TOKEN="$(BWS_ACCESS_TOKEN=$(cat ~/.config/bws/token) \
  bws --color no secret list "$(cat ~/.config/bws/sb-project-id)" \
  | jq -r '.[] | select(.key=="DISCORD_BOT_TOKEN") | .value')"
CH=1470991417836044359
MSG=1535757382322225153

# 1. Snapshot the live message FIRST (this is the rollback).
curl -sS -H "authorization: Bot $BOT_TOKEN" \
  "https://discord.com/api/v10/channels/$CH/messages/$MSG" > /tmp/ann-backup.json

# 2. Edit with the amended body.
curl -sS -X PATCH "https://discord.com/api/v10/channels/$CH/messages/$MSG" \
  -H "authorization: Bot $BOT_TOKEN" -H 'content-type: application/json' \
  --data @docs/announcements/suite-roster-embeds.json
```

Use `curl`, not `python3 urllib`: Cloudflare fronts the Discord API and
rejects the default `Python-urllib` user agent with a bare `error code:
1010` body, which reads exactly like a Discord permission error and is
not one.

Discord limits worth pre-checking: 25 fields per embed, 1024 chars per
field value, 6000 chars per embed, 2000 chars of top-level content.

## A genuinely new moment (not a roster change)

Post a new Components V2 card (`flags: 32768`) only for a real event that
is not "the catalog changed". A V2 card cannot be created by editing a
plain message, so that path is a new post by construction.
