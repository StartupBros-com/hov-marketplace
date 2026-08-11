# Announcement payloads

Routine version drops post themselves to `#tool-drops` through the OIDC
release train. This directory holds the hand-built cards for the moments
that are NOT routine, so the copy is reviewable in a PR before it reaches
a member-facing channel.

## suite-launch-card.json

The `#announcements` card for the complete eight-tool catalog. Post it
once, deliberately, when the operator calls the launch. Components V2
(`flags: 32768`), so it must be POSTed as a new message: a V2 card cannot
be created by editing a plain message.

```bash
BOT_TOKEN="$(BWS_ACCESS_TOKEN=$(cat ~/.config/bws/token) \
  bws --color no secret list "$(cat ~/.config/bws/sb-project-id)" \
  | jq -r '.[] | select(.key=="DISCORD_BOT_TOKEN") | .value')"

curl -sS -X POST "https://discord.com/api/v10/channels/1470991417836044359/messages" \
  -H "authorization: Bot $BOT_TOKEN" \
  -H 'content-type: application/json' \
  --data @docs/announcements/suite-launch-card.json
```

Channel `1470991417836044359` is `#📣│announcements`. Verify by reading the
returned message id; the bot lacks the message-content intent, so a later
channel read shows empty content on webhook-authored posts.
