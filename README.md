# claudex-setup

Run OpenAI's GPT models *inside* Claude Code, alongside normal Claude, and move a
live session between the two without losing the conversation.

## Background

Claude Code only talks to Anthropic models out of the box. CLIProxyAPI is a small
local proxy that speaks the Anthropic API on one side and forwards to OpenAI (via
your Codex login) on the other. Point Claude Code's `ANTHROPIC_BASE_URL` at that
local proxy instead of Anthropic's servers, and Claude Code will happily drive
GPT-5.6 Sol (1M+ token context, up to 128K output, adjustable reasoning effort) as
if it were a Claude model. Same tool use, same subagents, same UI.

Anthropic doesn't officially support this. It's a community trick (sometimes
called "Claudex"), fine for solo experimentation, **not** something to run for a
team without your own auth/audit/budget controls on top.

**Normal Claude stays stock.** The proxy is only in the path when you explicitly
ask for a GPT model. Plain `claude` goes straight to Anthropic, so a proxy outage
costs you the GPT side and nothing else, and your Anthropic credentials are never
handed to the proxy.

## Quick start

```bash
./setup.sh
```

Installs and configures CLIProxyAPI, generates and stores a local secret, walks
you through the Codex OAuth login (skipped if already authorized), verifies
GPT-5.6 Sol is reachable, links the `/switch` command into `~/.claude/commands/`,
and wires the `claude` wrapper into `~/.zshrc`. Safe to re-run.

Then `source ~/.zshrc` (or open a new terminal).

## Launching

| Command | Backend |
| --- | --- |
| `claude` | normal Claude Code, straight to Anthropic |
| `claude --gpt` | `gpt-5.6-sol` via the local proxy |
| `claude --gpt=terra` | a specific proxy model |
| `claude --gpt=sol:high` | ...with a reasoning effort (`minimal`/`low`/`medium`/`high`/`max`) |

Everything else passes straight through, e.g. `claude --gpt --continue`.

`claude` is a shell function wrapping the real binary. `claude -p ...` still
picks the backend you asked for, but gets no supervisor loop and no injected
hook, so plain `claude -p` in a script behaves exactly as it did before.

## Switching mid-session

Inside a session, `/switch` moves you to another backend and reloads the same
conversation there:

```
/switch terra        -> gpt-5.6-terra
/switch sol high     -> gpt-5.6-sol(high)
/switch 5.5          -> gpt-5.5
/switch opus         -> Anthropic, Opus
/switch claude       -> Anthropic, default model
```

Model names are resolved against whatever the proxy is actually serving, so new
models work without editing anything here. Anthropic targets never touch the
proxy.

### How the handover works

Nothing here runs in the background — there is no daemon and no extra server.

1. `/switch` runs `claudex-switch`, which writes a marker file naming the target
   model, this session's id, and its pid. It kills nothing itself. The marker is
   named after the supervisor shell, so two sessions open at once can never
   consume each other's requests.
2. A `Stop` hook fires the moment Claude finishes its reply — so the transcript is
   complete and safe to resume — and sends `SIGTERM` to that exact pid.
3. `claude` is a shell function running a `while` loop that was blocked waiting for
   the process to exit. It reads the marker, flips the environment, and relaunches
   with `--resume <same-session-id>`.

The loop is your shell, parked in `wait` at 0% CPU. It only executes between one
process ending and the next starting, and it exits when you exit Claude normally.

The `Stop` hook is injected per-launch via `claude --settings`, **not** written
into `~/.claude/settings.json`. It exists only in sessions started by this wrapper,
merges alongside any hooks you already have configured globally, and no-ops as a
single file-existence check on every other turn. A `claude` started by an IDE or a
script is untouched.

`claudex-switch` refuses to run if the session wasn't started by the wrapper,
since there would be no loop to catch the exit.

## Layout

```
runtime/claudex.zsh          the `claude` function and supervisor loop
runtime/claudex-common.sh    settings + model resolution, shared by zsh and bash
runtime/claudex-switch       writes the switch marker
runtime/claudex-stop-hook    hands the session over when a switch is pending
.claude/commands/switch.md   the /switch command, symlinked into ~/.claude/commands/
scripts/patch_conf.py        in-place patcher for cliproxyapi.conf
```

The repo is the source of truth. `~/.zshrc` sources `runtime/claudex.zsh` by
absolute path and `~/.claude/commands/switch.md` is a symlink, so edits here take
effect without re-installing. Moving this directory means re-running `setup.sh`.

State lives outside the repo: `~/.claudex_key` (proxy secret) and
`~/.claudex/switch-<pid>` (transient marker, one per running wrapper).

## Troubleshooting

- **401 from the proxy** → the secret in `~/.claudex_key` doesn't match the
  `api-keys` entry in CLIProxyAPI's config; re-run `./setup.sh`.
- **Unrecognized model** → `brew upgrade cliproxyapi` and redo
  `cliproxyapi --codex-login`.
- **400s around tool search** → drop `ENABLE_TOOL_SEARCH` to `false` in the gpt
  branch of `runtime/claudex.zsh`.
- **`/switch` says the session wasn't started by the wrapper** → you launched
  `claude` before `source ~/.zshrc`, or from something that bypasses the function.
- **A switch didn't relaunch** → check for a marker in `~/.claudex/`. Each
  wrapper clears its own on start and on exit, so anything left behind is stale
  and safe to delete.
- **Not sure which backend is active** → run `/status` inside Claude Code.
