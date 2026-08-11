# claudex: run Claude Code against Anthropic or against GPT models served by a
# local CLIProxyAPI gateway, and switch between them without losing the thread.
#
# Sourced from ~/.zshrc. Defines `claude` as a shell function wrapping the real
# binary. There is no daemon and no background process here: the function runs
# a loop that blocks waiting for Claude Code to exit, and only does anything in
# the instant between one process ending and the next starting.
#
#   claude                  normal Claude Code, straight to Anthropic
#   claude --gpt            Claude Code driven by gpt-5.6-sol via the proxy
#   claude --gpt=terra      a specific proxy model
#   claude --gpt=sol:high   ...with a reasoning effort
#
# Mid-session, /switch (see .claude/commands/switch.md) hands over to a
# different backend and reloads the same conversation.

CLAUDEX_DIR="${CLAUDEX_DIR:-${0:A:h}}"
source "$CLAUDEX_DIR/claudex-common.sh"

# Launch the real binary on the backend named by CLAUDEX_MODE/CLAUDEX_MODEL.
# $1 is a --settings JSON blob ("" to skip it); the rest are Claude Code args.
#
# CLAUDEX_SUPERVISOR is passed through only when a loop is actually waiting on
# this process, so claudex-switch can tell a handover it can complete from one
# that would drop the user at a bare shell.
_claudex_launch() {
  emulate -L zsh

  local settings="$1"
  shift

  # Built as arrays, not `${x:+--model "$x"}`: that form expands to a single
  # word in zsh, so the flag and its value would arrive as one argument.
  local -a settings_args=() model_args=() supervisor_args=()
  [[ -n "$settings" ]] && settings_args=(--settings "$settings")
  [[ -n "$CLAUDEX_MODEL" ]] && model_args=(--model "$CLAUDEX_MODEL")
  [[ -n "${CLAUDEX_SUPERVISOR:-}" ]] && supervisor_args=("CLAUDEX_SUPERVISOR=$CLAUDEX_SUPERVISOR")

  if [[ "$CLAUDEX_MODE" == "gpt" ]]; then
    env \
      "${supervisor_args[@]}" \
      "CLAUDEX_DIR=$CLAUDEX_DIR" \
      "ANTHROPIC_BASE_URL=$CLAUDEX_BASE_URL" \
      "ANTHROPIC_AUTH_TOKEN=$(claudex_key)" \
      "CLAUDE_CODE_SUBAGENT_MODEL=$CLAUDEX_MODEL" \
      "CLAUDE_CODE_MAX_CONTEXT_TOKENS=$CLAUDEX_CONTEXT_TOKENS" \
      CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3 \
      ENABLE_TOOL_SEARCH=auto:5 \
      claude "${model_args[@]}" "${settings_args[@]}" "$@"
  else
    # Strip any proxy variables that leaked in from a previous switch, so
    # plain Claude always talks to Anthropic directly.
    env \
      -u ANTHROPIC_BASE_URL \
      -u ANTHROPIC_AUTH_TOKEN \
      -u CLAUDE_CODE_SUBAGENT_MODEL \
      -u CLAUDE_CODE_MAX_CONTEXT_TOKENS \
      -u ENABLE_TOOL_SEARCH \
      -u CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY \
      "${supervisor_args[@]}" \
      "CLAUDEX_DIR=$CLAUDEX_DIR" \
      claude "${model_args[@]}" "${settings_args[@]}" "$@"
  fi
}

claude() {
  emulate -L zsh

  local spec="" passthrough=0
  local -a args
  while (( $# )); do
    case "$1" in
      --gpt)   spec="gpt" ;;
      --gpt=*) spec="${1#--gpt=}" ;;
      # Non-interactive runs still pick a backend, but get no supervisor loop
      # and no injected hook — there is nothing to switch. Scripts calling
      # plain `claude -p` behave exactly as they did before.
      -p|--print) passthrough=1; args+=("$1") ;;
      *) args+=("$1") ;;
    esac
    shift
  done

  local target="$spec" effort=""
  if [[ "$spec" == *:* ]]; then
    target="${spec%%:*}"
    effort="${spec#*:}"
  fi

  claudex_resolve "$target" "$effort" || return 1

  # --gpt is consumed here rather than forwarded: the real binary ignores
  # flags it does not recognise, so passing it on would silently run the
  # wrong backend instead of failing.
  if (( passthrough )); then
    _claudex_launch "" "${args[@]}"
    return $?
  fi

  mkdir -p "$CLAUDEX_STATE_DIR"

  # This shell is the supervisor. Naming the marker after it keeps concurrent
  # sessions from consuming each other's switch requests.
  local CLAUDEX_SUPERVISOR=$$
  local switch_file
  switch_file="$(claudex_switch_file "$CLAUDEX_SUPERVISOR")"
  rm -f "$switch_file"

  # Injected per-launch rather than written into ~/.claude/settings.json, so
  # this hook exists only in sessions started here and merges with whatever
  # hooks are already configured globally.
  local hook_json
  hook_json='{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'"$CLAUDEX_DIR/claudex-stop-hook"'"}]}]}}'

  local -a run_args
  run_args=("${args[@]}")
  # Not `status`: zsh reserves that name as a read-only alias for $?.
  local rc=0

  while true; do
    _claudex_launch "$hook_json" "${run_args[@]}"
    rc=$?

    [[ -f "$switch_file" ]] || break

    local next_mode next_model next_session
    next_mode="$(claudex_marker_get "$switch_file" mode)"
    next_model="$(claudex_marker_get "$switch_file" model)"
    next_session="$(claudex_marker_get "$switch_file" session)"
    rm -f "$switch_file"

    [[ -n "$next_mode" ]] || break

    CLAUDEX_MODE="$next_mode"
    CLAUDEX_MODEL="$next_model"

    if [[ -n "$next_session" ]]; then
      run_args=(--resume "$next_session")
    else
      run_args=(--continue)
    fi

    print -P "%F{blue}==>%f resuming on %B${next_model:-Claude (default model)}%b"
  done

  rm -f "$switch_file"
  return $rc
}
