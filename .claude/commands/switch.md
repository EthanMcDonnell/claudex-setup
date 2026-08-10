---
description: Switch this session to a different backend model (GPT via the local proxy, or Anthropic) and reload the conversation there
argument-hint: [gpt|sol|terra|luna|5.5|opus|sonnet|claude] [minimal|low|medium|high|max]
allowed-tools: Bash(claudex-switch:*)
---

Run exactly this, passing the arguments straight through:

```
claudex-switch $ARGUMENTS
```

Then:

- **If it fails**, report its error output verbatim and stop. Do not retry, do not try to switch by another route, and do not edit any files.
- **If it succeeds**, reply with a single short line naming the model being switched to, then **stop immediately**.

Do no other work in this turn once the command succeeds. The session ends as
soon as your reply does — a Stop hook hands over to the new backend and the
supervisor relaunches with this same conversation. Anything else you begin here
will be cut off mid-flight.
