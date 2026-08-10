# claudex-setup

Run OpenAI's GPT-5.6 Sol model *inside* Claude Code, alongside normal Claude. Switch between the two with one command.

## Background

Claude Code only talks to Anthropic models out of the box. CLIProxyAPI is a small local proxy that speaks the Anthropic API on one side and forwards to OpenAI (via your Codex login) on the other. Point Claude Code's `ANTHROPIC_BASE_URL` at that local proxy instead of Anthropic's servers, and Claude Code will happily drive GPT-5.6 Sol (1M+ token context, up to 128K output, adjustable reasoning effort) as if it were a Claude model. Same tool use, same subagents, same UI.

Anthropic doesn't officially support this. It's a community trick (sometimes called "Claudex"), fine for solo experimentation, **not** something to run for a team without your own auth/audit/budget controls on top.

## Quick start

```bash
./setup.sh
```

This installs and configures CLIProxyAPI, generates and stores a local secret, walks you through the Codex OAuth login, verifies GPT-5.6 Sol is reachable, and installs an `agent` shell function into `~/.zshrc`. Safe to re-run any time. It refreshes the config instead of duplicating it.

Then `source ~/.zshrc` (or open a new terminal) and:

- `agent claude` (or just `claude`) → normal Claude Code, Anthropic models.
- `agent gpt` → Claude Code driven by GPT-5.6 Sol through the local proxy.

Extra args pass straight through either way, e.g. `agent gpt --continue`. For a specific reasoning level, edit the `agent` function in `~/.zshrc` to use `--model 'gpt-5.6-sol(high)'` (or `low`/`medium`/`max`).

## Troubleshooting

- **401 from the proxy** → the secret in `~/.claudex_key` doesn't match the `api-keys` entry in CLIProxyAPI's config; re-run `./setup.sh`.
- **Unrecognized model** → `brew upgrade cliproxyapi` and redo `cliproxyapi --codex-login`.
- **400s around tool search** → set `ENABLE_TOOL_SEARCH=false` in the `agent gpt` case and retry.
- **Not sure which backend is active** → run `/status` inside Claude Code.
