# House of Vibe Claude Code marketplace

Claude Code tools for builders. Add the marketplace over HTTPS once, then install any of the tools:

```text
/plugin marketplace add https://github.com/StartupBros-com/hov-marketplace.git
/plugin install token-eater@hov
/plugin install pro-gate@hov
/plugin install wsl-cdp@hov
/plugin install skill-tuner@hov
/plugin install memory-dream@hov
```

Third-party marketplace updates are off by default. Open `/plugin`, select **Marketplaces**, choose `hov`, and select **Enable auto-update**. Updates are applied at the start of a Claude Code session.

## token-eater

Put expiring AI credits to work on reviewed code cleanup. Run `/token-eater` and it works in an isolated copy, verifies the result, reviews it, and opens a draft pull request. It never merges.

Token-eater executes shell commands unsandboxed on the target repository. Its first-run preflight shows this disclosure and requires consent before any command runs. Use it only on repositories you trust.

Token-eater uses the compound-engineering code-review personas. Install that companion plugin if it is not already available:

```text
/plugin install compound-engineering@every-marketplace
```

## pro-gate

Run `/pro-gate` for a final pull request review using the Pro model selected by your ChatGPT account. It reviews the change, fixes what it safely can, and leaves a report. It never merges.

The first run routes through the doctor to install the runtime that matches the promoted plugin release. The automatic fixer daemon remains off unless you explicitly enable it and accept its target-repository execution disclosure. A ChatGPT Pro plan is required.

## wsl-cdp

Drive your real, logged-in Windows browser (Chrome, Edge, or Brave) from Claude Code running inside WSL2, over the Chrome DevTools Protocol — read authenticated dashboards, take real screenshots, manage tabs. Fills the gap the Claude in Chrome extension cannot cover under WSL2.

Run `/wsl-cdp:setup` for the guided one-time setup: one elevated UAC step on the Windows side, an explicit choice of which browser the agent should use, and your one-time site logins. The agent browser is a dedicated, hardened profile — you pick the vendor, the profile stays bound to it, and it keeps sessions, never passwords (password saving and browser sign-in are disabled per-profile; anything saved anyway is scrubbed at the next launch). Native-Windows and macOS users are routed to the official Claude in Chrome extension instead. WSL2 with NAT networking (the default) is assumed. Details: [StartupBros-com/wsl-cdp](https://github.com/StartupBros-com/wsl-cdp).

## skill-tuner

Tell whether a change to an agent-consumed document actually worked. `/skill-tuner:tune` probes a `SKILL.md`, `AGENTS.md`, or `CLAUDE.md`, fixes what three independent skeptics confirm, and proves the description still routes — paired comparison with a confidence interval, and content-hashed provenance with drift detection.

## memory-dream

The sleep cycle for Claude Code's auto-memory. `/memory-dream:dream` runs an operator-gated consolidation pass: deterministic triage finds superseded, stale, and oversized notes, a zero-tool subagent drafts the fixes it cannot apply, and you approve each change by hand before anything is written. `/memory-dream:eval` measures whether recall actually improved. It never merges, deletes, or compresses a note on its own.

## License

MIT
