# claudex-setup

Notes and config for running OpenAI's GPT-5.6 Sol model *inside* Claude Code, alongside normal Claude — plus a one-command switcher between the two.

## Background

Claude Code only talks to Anthropic models out of the box. CLIProxyAPI is a small local proxy that speaks the Anthropic API on one side and forwards to OpenAI (via your Codex login) on the other. Point Claude Code's `ANTHROPIC_BASE_URL` at that local proxy instead of Anthropic's servers, and Claude Code will happily drive GPT-5.6 Sol (1M+ token context, up to 128K output, adjustable reasoning effort) as if it were a Claude model — same tool use, same subagents, same UI.

Anthropic doesn't officially support this — it's a community trick (sometimes called "Claudex"), fine for solo experimentation, **not** something to run for a team without your own auth/audit/budget controls on top.

## One-time setup

```bash
# install + start the proxy
brew install cliproxyapi
brew services start cliproxyapi

# generate a strong local secret
openssl rand -hex 32
```

Edit `$(brew --prefix)/etc/cliproxyapi.conf`:

```yaml
host: "127.0.0.1"      # keep it off the network — never expose this port publicly
port: 8317
remote-management:
  allow-remote: false
api-keys:
  - "PASTE_YOUR_GENERATED_SECRET_HERE"
```

```bash
brew services restart cliproxyapi
cliproxyapi --codex-login          # authorizes the proxy against your OpenAI/Codex account

# sanity check — should list gpt-5.6-sol
curl -sS http://127.0.0.1:8317/v1/models \
  -H "Authorization: Bearer PASTE_YOUR_GENERATED_SECRET_HERE"
```

Credentials from the login live in `~/.cli-proxy-api` — don't commit that directory anywhere.

## Switching between Claude and Codex

Rather than juggling long inline env-var incantations, drop this function in `~/.zshrc`:

```bash
export CLAUDEX_KEY="PASTE_YOUR_GENERATED_SECRET_HERE"

agent() {
  case "$1" in
    gpt|codex)
      shift
      ANTHROPIC_BASE_URL=http://127.0.0.1:8317 \
      ANTHROPIC_AUTH_TOKEN="$CLAUDEX_KEY" \
      CLAUDE_CODE_SUBAGENT_MODEL=gpt-5.6-sol \
      CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3 \
      ENABLE_TOOL_SEARCH=auto:5 \
      claude --model gpt-5.6-sol "$@"
      ;;
    claude|"")
      shift
      command claude "$@"
      ;;
    *)
      echo "usage: agent [claude|gpt] [claude-code args...]"
      return 1
      ;;
  esac
}
```

Then:

- `agent claude` (or plain `claude`) → normal Claude Code, Anthropic models.
- `agent gpt` → Claude Code driven by GPT-5.6 Sol through the local proxy.

Any extra args pass straight through, e.g. `agent gpt --continue` or `agent claude -p "..."`. For a specific reasoning level with GPT-5.6 Sol, edit the alias to use `--model 'gpt-5.6-sol(high)'` (or `low`/`medium`/`max`).

## Troubleshooting

- **401 from the proxy** → `ANTHROPIC_AUTH_TOKEN` doesn't match the `api-keys` entry in `cliproxyapi.conf`.
- **Unrecognized model** → update CLIProxyAPI and redo `--codex-login`.
- **400s around tool search** → set `ENABLE_TOOL_SEARCH=false` and retry.
- **Not sure which backend is active** → run `/status` inside Claude Code.
