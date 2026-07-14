# House of Vibe Claude Code marketplace

Claude Code tools for builders. Add the marketplace over HTTPS once, then install either or both tools:

```text
/plugin marketplace add https://github.com/StartupBros-com/hov-marketplace.git
/plugin install token-eater@hov
/plugin install pro-gate@hov
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

## License

MIT
