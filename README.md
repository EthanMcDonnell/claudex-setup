# claudex-setup

Run OpenAI's GPT models *inside* Claude Code, alongside normal Claude, and move a
live session between the two without losing the conversation.

## Background

Claude Code only talks to Anthropic models out of the box. CLIProxyAPI is a small
local proxy that speaks the Anthropic API on one side and forwards to OpenAI (via
your Codex login) on the other. Point Claude Code's `ANTHROPIC_BASE_URL` at that
local proxy instead of Anthropic's servers, and Claude Code will happily drive
GPT-5.6 Sol (272K token context, adjustable reasoning effort) as if it were a
Claude model. Same tool use, same subagents, same UI.

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

## Context window

Every model the proxy currently serves has the same window. Measured by running
`codex -m <model>`, sending a prompt, then `/status`:

| Model | Raw window | Usable |
| --- | --- | --- |
| gpt-5.6-sol | 272,000 | 258,000 |
| gpt-5.6-terra | 272,000 | 258,000 |
| gpt-5.6-luna | 272,000 | 258,000 |
| gpt-5.5 | 272,000 | 258,000 |

Reasoning effort does not change it — the window is a property of the model, so
`sol:high` and `sol:low` get the same 258K. `gpt-5.4` and `gpt-5.4-mini` are
deprecated aliases that resolve to terra and luna, and inherit their windows.

The 14K gap is a 5% reserve Codex holds back; `/status` reports only the usable
figure. `codex --version` 0.147.0 caches all of this in
`~/.codex/models_cache.json`, which is where the raw numbers above come from.

Claude Code has no table entry for a `gpt-*` model name, so left alone it assumes
**200,000** tokens and auto-compacts there, ~23% early. The wrapper therefore
exports `CLAUDE_CODE_MAX_CONTEXT_TOKENS` (see `CLAUDEX_CONTEXT_TOKENS` in
`runtime/claudex-common.sh`, default 258000). That variable applies only to model
names that do not start with `claude-`, so it cannot affect the Anthropic side;
the wrapper unsets it there anyway.

Set `CLAUDEX_CONTEXT_TOKENS` in your environment to override, and re-measure with
`/status` when new models show up.

### Why not CLIProxyAPI's own setting

CLIProxyAPI has a `max-context-length` key, and it looks like the right knob. It
isn't, for two reasons:

- It rewrites the model catalog served to **Codex** clients. Claude Code speaks
  the Anthropic protocol and never fetches a catalog, so it never sees the value.
- It lives under a credential's `models:` list, which exists only for API-key
  providers (`codex-api-key`, `openai-compatibility`, and friends). This setup
  authenticates with Codex OAuth, whose auth files hold tokens and nothing else,
  so there is no `models:` list to put it in.

Both sides of that are worth knowing before reaching for the config again.

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
