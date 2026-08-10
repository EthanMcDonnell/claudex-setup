#!/usr/bin/env bash
# claudex-setup: one-shot installer for running GPT-5.6 Sol inside Claude Code
# via a local CLIProxyAPI gateway, plus an `agent` command to switch between
# plain Claude Code and the GPT-5.6 Sol backend.
#
# Safe to re-run: re-running just refreshes the config and the ~/.zshrc block.
set -euo pipefail

PORT=8317
ZSHRC="${HOME}/.zshrc"
KEY_FILE="${HOME}/.claudex_key"
MARK_START="# >>> claudex-setup >>>"
MARK_END="# <<< claudex-setup <<<"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

command -v brew >/dev/null 2>&1 || die "Homebrew is required — install it from https://brew.sh first."

log "Installing CLIProxyAPI"
if brew list cliproxyapi >/dev/null 2>&1; then
  echo "already installed"
else
  brew install cliproxyapi
fi

log "Starting the CLIProxyAPI service"
brew services start cliproxyapi >/dev/null

CONF_PATH="$(brew --prefix)/etc/cliproxyapi.conf"
[ -f "$CONF_PATH" ] || die "expected a config at $CONF_PATH — CLIProxyAPI's install layout may have changed."

if [ -f "$KEY_FILE" ]; then
  SECRET="$(cat "$KEY_FILE")"
  log "Reusing existing local secret ($KEY_FILE)"
else
  log "Generating a local secret"
  SECRET="$(openssl rand -hex 32)"
  printf '%s\n' "$SECRET" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
fi

log "Writing $CONF_PATH"
cp "$CONF_PATH" "${CONF_PATH}.bak.$(date +%s)" 2>/dev/null || true
cat > "$CONF_PATH" <<EOF
host: "127.0.0.1"
port: ${PORT}
remote-management:
  allow-remote: false
  secret-key: ""
api-keys:
  - "${SECRET}"
EOF

log "Restarting CLIProxyAPI so the new config takes effect"
brew services restart cliproxyapi >/dev/null
sleep 2

log "Authorizing the proxy against your OpenAI/Codex account"
echo "(this opens a browser for OAuth — finish the login there, then come back)"
cliproxyapi --codex-login

log "Confirming gpt-5.6-sol is reachable through the proxy"
if curl -sS "http://127.0.0.1:${PORT}/v1/models" -H "Authorization: Bearer ${SECRET}" | grep -q gpt-5.6-sol; then
  echo "confirmed: gpt-5.6-sol is available"
else
  die "gpt-5.6-sol not found in the proxy's model list — re-check the codex-login step above."
fi

log "Installing the 'agent' switcher into ${ZSHRC}"
touch "$ZSHRC"
if grep -qF "$MARK_START" "$ZSHRC"; then
  sed -i.bak "/${MARK_START}/,/${MARK_END}/d" "$ZSHRC"
fi

cat >> "$ZSHRC" <<'EOF'
# >>> claudex-setup >>>
agent() {
  case "$1" in
    gpt|codex)
      shift
      ANTHROPIC_BASE_URL=http://127.0.0.1:8317 \
      ANTHROPIC_AUTH_TOKEN="$(cat "$HOME/.claudex_key" 2>/dev/null)" \
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
# <<< claudex-setup <<<
EOF

log "Done"
echo "Run 'source ~/.zshrc' (or open a new terminal), then:"
echo "  agent claude   -> normal Claude Code"
echo "  agent gpt      -> Claude Code driven by GPT-5.6 Sol"
