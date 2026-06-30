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

---

_Status: WIP / private — not yet announced to members. Flip to public at launch._
