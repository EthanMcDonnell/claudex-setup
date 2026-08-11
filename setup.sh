#!/usr/bin/env bash
# claudex-setup: one-shot installer for running GPT models inside Claude Code
# via a local CLIProxyAPI gateway, plus a `claude` wrapper and a /switch command
# for moving a live session between backends without losing the conversation.
#
# Safe to re-run: re-running just refreshes the config, the symlink, and the
# ~/.zshrc block. Replaces the older `agent` function if one is still installed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${SCRIPT_DIR}/runtime"
COMMANDS_DIR="${HOME}/.claude/commands"
PORT=8317
ZSHRC="${HOME}/.zshrc"
KEY_FILE="${HOME}/.claudex_key"
MARK_START="# >>> claudex-setup >>>"
MARK_END="# <<< claudex-setup <<<"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

command -v brew >/dev/null 2>&1 || die "Homebrew is required — install it from https://brew.sh first."
command -v python3 >/dev/null 2>&1 || die "python3 is required (used to patch cliproxyapi.conf in place)."

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

log "Patching $CONF_PATH"
cp "$CONF_PATH" "${CONF_PATH}.bak.$(date +%s)" 2>/dev/null || true
python3 "${SCRIPT_DIR}/scripts/patch_conf.py" "$CONF_PATH" "$PORT" "$SECRET"

log "Restarting CLIProxyAPI so the new config takes effect"
brew services restart cliproxyapi >/dev/null
sleep 2

fetch_models() {
  curl -sS -m 10 "http://127.0.0.1:${PORT}/v1/models" -H "Authorization: Bearer ${SECRET}" 2>/dev/null || true
}

# Only send the user through a browser OAuth flow if the proxy cannot already
# serve models. Re-running setup should not cost a fresh login.
log "Checking whether the proxy is already authorized"
MODELS_JSON="$(fetch_models)"
if printf '%s' "$MODELS_JSON" | grep -q '"id"'; then
  echo "already authorized — skipping the Codex login"
else
  echo "no models available yet — starting the OAuth flow"
  echo "(this opens a browser — finish the login there, then come back)"
  cliproxyapi --codex-login
  MODELS_JSON="$(fetch_models)"
fi

log "Confirming gpt-5.6-sol is reachable through the proxy"
if printf '%s' "$MODELS_JSON" | grep -q gpt-5.6-sol; then
  echo "confirmed: gpt-5.6-sol is available"
else
  echo "gpt-5.6-sol not found. Models currently available to this account:"
  MODELS_JSON="$MODELS_JSON" python3 -c '
import json, os
raw = os.environ.get("MODELS_JSON", "")
try:
    data = json.loads(raw)
    for m in data.get("data", []):
        print("  -", m.get("id"))
except Exception:
    print("  (could not parse proxy response)")
    print(" ", raw)
'
  die "gpt-5.6-sol not available — see the model list above (often a plan/subscription tier gate, not a login problem)."
fi

# Sourced rather than hardcoded so this figure and the one the wrapper actually
# exports can never drift apart.
. "${RUNTIME_DIR}/claudex-common.sh"
log "Context window Claude Code will assume for proxy models"
echo "${CLAUDEX_CONTEXT_TOKENS} tokens — without this it would assume 200000 for any gpt-* name"
echo "to re-measure: run 'codex -m gpt-5.6-sol', send any prompt, then /status"

log "Making the runtime scripts executable"
chmod +x "${RUNTIME_DIR}/claudex-switch" "${RUNTIME_DIR}/claudex-stop-hook"

log "Linking the /switch command into ${COMMANDS_DIR}"
mkdir -p "$COMMANDS_DIR"
ln -sfn "${SCRIPT_DIR}/.claude/commands/switch.md" "${COMMANDS_DIR}/switch.md"
echo "linked $(basename "${COMMANDS_DIR}")/switch.md -> ${SCRIPT_DIR}/.claude/commands/switch.md"

log "Wiring the claude wrapper into ${ZSHRC}"
touch "$ZSHRC"
if grep -qF "$MARK_START" "$ZSHRC"; then
  sed -i.bak "/${MARK_START}/,/${MARK_END}/d" "$ZSHRC"
fi

# The repo is the source of truth: ~/.zshrc points at it rather than holding a
# copy, so editing runtime/ takes effect in the next shell with no re-install.
cat >> "$ZSHRC" <<EOF
${MARK_START}
export CLAUDEX_DIR="${RUNTIME_DIR}"
export PATH="\${CLAUDEX_DIR}:\${PATH}"
source "\${CLAUDEX_DIR}/claudex.zsh"
${MARK_END}
EOF

log "Done"
echo "Run 'source ~/.zshrc' (or open a new terminal), then:"
echo "  claude                -> normal Claude Code, straight to Anthropic"
echo "  claude --gpt          -> Claude Code driven by gpt-5.6-sol"
echo "  claude --gpt=terra    -> a specific proxy model"
echo "  claude --gpt=sol:high -> ...with a reasoning effort"
echo
echo "Mid-session, switch without losing the conversation:"
echo "  /switch terra"
echo "  /switch sol high"
echo "  /switch claude"
