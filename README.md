# House of Vibe — Claude Code marketplace

Claude Code tools for vibe coders. Add this marketplace once, then install what you want.

```
/plugin marketplace add StartupBros-com/hov-marketplace
/plugin install token-eater@hov
```

## token-eater

Put your about-to-expire AI credits to work. Just run `/token-eater` — it tidies up your code in an
isolated copy of your project, double-checks nothing broke, reviews it, and opens a **draft pull
request** for you to look at. It never merges; you decide.

**Required companion — compound-engineering** (token-eater uses its code-review personas):

```
/plugin install compound-engineering@every-marketplace
```

token-eater will also prompt you to install it the first time if it's missing. Without it, the review
falls back to a lighter generic pass (clearly labeled).

## pro-gate

```
/plugin install pro-gate@hov
```

Get the **deepest final review** of your code before you merge — from **GPT-5.5 Pro**, ChatGPT's most
powerful model. Just run `/pro-gate` on your pull request: it reads your change, finds what other
checks missed, fixes what it safely can, and leaves you a write-up. It never merges; you decide.

The first time you run it, `/pro-gate` walks you through a one-time setup (a few clicks). **You need a
ChatGPT Pro plan** — that's where GPT-5.5 Pro lives — and pro-gate sets up everything else for you.

Great paired with token-eater: `/token-eater` cleans up your code and opens a draft PR, then
`/pro-gate` gives that PR the deepest review before you merge.

---

_Status: WIP / private — not yet announced to members. Flip to public at launch._
