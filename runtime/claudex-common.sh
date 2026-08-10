#!/usr/bin/env bash
# Shared settings and model resolution for claudex.
#
# Sourced by both bash scripts (claudex-switch, claudex-stop-hook) and by zsh
# (claudex.zsh), so everything here sticks to syntax both shells agree on:
# no arrays, no `declare -A`, and no reliance on unquoted word splitting —
# zsh does not split unquoted parameters the way bash does.

CLAUDEX_PORT="${CLAUDEX_PORT:-8317}"
CLAUDEX_BASE_URL="http://127.0.0.1:${CLAUDEX_PORT}"
CLAUDEX_KEY_FILE="${CLAUDEX_KEY_FILE:-$HOME/.claudex_key}"
CLAUDEX_STATE_DIR="${CLAUDEX_STATE_DIR:-$HOME/.claudex}"

claudex_key() { cat "$CLAUDEX_KEY_FILE" 2>/dev/null; }

# Path to the switch marker for one supervisor loop.
#
# There is a marker per supervisor rather than one global file, because two
# wrapped sessions can be open at once: a single shared path lets one session
# consume the other's request and resume the wrong conversation. The id is the
# supervisor shell's pid, exported as CLAUDEX_SUPERVISOR and inherited by
# claudex-switch and the Stop hook running inside that session.
#
# Usage: claudex_switch_file [supervisor-id]
claudex_switch_file() {
  printf '%s/switch-%s\n' "$CLAUDEX_STATE_DIR" "${1:-${CLAUDEX_SUPERVISOR:-none}}"
}

# Model ids the proxy is currently serving, one per line. Empty output means
# the proxy is unreachable or rejecting our key — callers must treat that as
# a hard failure rather than "no models".
claudex_proxy_models() {
  curl -sS -m 5 "$CLAUDEX_BASE_URL/v1/models" \
    -H "Authorization: Bearer $(claudex_key)" 2>/dev/null |
    python3 -c '
import json, sys
try:
    for m in json.load(sys.stdin).get("data", []):
        print(m.get("id", ""))
except Exception:
    pass
'
}

# Resolve a user-facing target ("gpt", "terra", "opus", a full model id) into
# CLAUDEX_MODE (anthropic|gpt) and CLAUDEX_MODEL. Anthropic targets never touch
# the proxy, so normal Claude still works with the proxy stopped.
#
# Usage: claudex_resolve <target> [effort]
claudex_resolve() {
  claudex_target="${1:-}"
  claudex_effort="${2:-}"
  CLAUDEX_MODE=""
  CLAUDEX_MODEL=""

  case "$claudex_target" in
    "" | claude | anthropic)
      CLAUDEX_MODE="anthropic"
      CLAUDEX_MODEL=""
      return 0
      ;;
    opus | sonnet | haiku | fable | claude-*)
      CLAUDEX_MODE="anthropic"
      CLAUDEX_MODEL="$claudex_target"
      return 0
      ;;
    gpt)
      claudex_target="gpt-5.6-sol"
      ;;
  esac

  claudex_models="$(claudex_proxy_models)"
  if [ -z "$claudex_models" ]; then
    echo "claudex: the proxy at $CLAUDEX_BASE_URL is not answering." >&2
    echo "claudex: try 'brew services restart cliproxyapi', or re-run setup.sh." >&2
    return 1
  fi

  # Exact id first, then <family>-<alias> (terra -> gpt-5.6-terra), then any
  # substring. Most specific wins so a bare "5.5" cannot shadow "gpt-5.5".
  claudex_match="$(printf '%s\n' "$claudex_models" | grep -ixF "$claudex_target" | head -1)"
  [ -n "$claudex_match" ] || claudex_match="$(printf '%s\n' "$claudex_models" | grep -iE "^gpt-[0-9.]+-${claudex_target}$" | head -1)"
  [ -n "$claudex_match" ] || claudex_match="$(printf '%s\n' "$claudex_models" | grep -iE "^gpt-${claudex_target}$" | head -1)"
  [ -n "$claudex_match" ] || claudex_match="$(printf '%s\n' "$claudex_models" | grep -iF -- "$claudex_target" | head -1)"

  if [ -z "$claudex_match" ]; then
    echo "claudex: no model matches '${1}'. The proxy is serving:" >&2
    printf '%s\n' "$claudex_models" | while IFS= read -r claudex_line; do
      [ -n "$claudex_line" ] && printf '  - %s\n' "$claudex_line" >&2
    done
    echo "claudex: Anthropic side: claude, opus, sonnet, haiku, fable." >&2
    return 1
  fi

  case "$claudex_effort" in
    "") ;;
    minimal | low | medium | high | max)
      claudex_match="${claudex_match}(${claudex_effort})"
      ;;
    *)
      echo "claudex: unknown reasoning effort '$claudex_effort' (use minimal, low, medium, high, max)." >&2
      return 1
      ;;
  esac

  CLAUDEX_MODE="gpt"
  CLAUDEX_MODEL="$claudex_match"
  return 0
}

# Read one key from a switch marker without eval'ing the file.
#
# Usage: claudex_marker_get <marker-file> <key>
claudex_marker_get() {
  claudex_file="$1"
  claudex_want="$2"
  [ -f "$claudex_file" ] || return 1
  while IFS='=' read -r claudex_k claudex_v; do
    if [ "$claudex_k" = "$claudex_want" ]; then
      printf '%s\n' "$claudex_v"
      return 0
    fi
  done <"$claudex_file"
  return 1
}
