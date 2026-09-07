---
name: interactive-cli-automation
description: Use when a CLI wizard blocks on Y/n or secret prompts.
---

# Interactive CLI Automation

## Trigger

Any CLI tool that blocks waiting for terminal input mid-run: setup wizards
(`hermes mcp add`, `gh auth login`, `npm init`, `aws configure`, `gcloud init`),
Y/n confirmations, or a masked secret/password prompt. Symptoms in the
`terminal` tool: the command "hangs" until timeout, or output ends mid-sentence
with no trailing newline (`API key / Bearer token: `) and never returns.

## Ground rule: never wrap in shell backgrounding

`terminal` explicitly rejects `&`, `nohup`, `disown`, `setsid` — it detects
these wrappers and errors out asking for `background=true` instead. Don't
fight this; it exists so the harness can actually track and interact with the
child process (poll it, write to its stdin, kill it). Use the tool's own
background mode from the start.

## The actual pattern

1. **Launch with `background=true` AND `pty=true`.** Many interactive CLIs
   (anything using `getpass`, `readline`, or a TTY-detecting prompt library)
   refuse to prompt at all — or warn "password may be echoed" — without a real
   pty. `pty=true` alone still blocks the foreground call in real time and
   consumes your interaction budget; pairing it with `background=true` gets a
   `session_id` back immediately so you can drive the conversation turn by
   turn.

2. **Use the tool's OWN absolute path, not a bare command name.** A
   `background=true` process does not inherit the interactive shell's
   PATH/rc-file exports — a command that resolves fine in a normal foreground
   `terminal()` call can fail with `command not found` in background mode.
   Resolve the absolute path first (`which <tool>` in an ordinary foreground
   call) and launch that, e.g. `/opt/hermes/bin/hermes mcp add ...` instead of
   `hermes mcp add ...`.

3. **Poll to read the current prompt.** `process(action='poll', session_id=...)`
   returns `output_preview` ending in whatever the tool most recently printed
   — that's your cue for what it's waiting for (`[Y/n]:`, `API key:`, etc.).

4. **Answer with `process(action='submit', ...)`, never by putting the answer
   in the original command string.** This is the actual security payoff:
   a secret typed into `submit`'s `data` field goes straight to the child's
   stdin and never appears in the `command` you passed to `terminal`, so it
   never lands in shell history, tool-call logs, or anywhere else a command
   string gets echoed/audited. Use `submit` (adds Enter) for line-based
   answers like `Y` or a pasted token; use `write` only if you need to send
   raw bytes without a trailing newline.

5. **`process(action='wait', timeout=N)` between steps, and expect a
   `status: timeout` response while the wizard is still waiting on your next
   answer** — that's not a failure, it's the process correctly blocked on
   stdin. Re-poll/re-submit until `status: exited`.

6. **Check the final `output`/exit code, not just "it returned."** Wizards
   often print a confirmation of what got saved (e.g. `Saved to /path/.env as
   KEY_NAME`) — that's your proof the secret went where it should (a `.env`/
   secret store) and not into a config file meant for non-secret settings.

## Worked example (Hermes MCP server with a bearer-token API key)

```
# 1. Resolve the absolute binary path first, in an ordinary foreground call.
which hermes   # -> /opt/hermes/bin/hermes

# 2. Launch the wizard in background+pty.
terminal(command='/opt/hermes/bin/hermes mcp add mailfallback --url "https://host/mcp/" --auth header',
         background=true, pty=true)
# -> {"session_id": "proc_xxx", ...}

# 3. Poll, see it waiting on the first prompt.
process(action='poll', session_id='proc_xxx')
# -> output_preview: "...Does this server require authentication? [Y/n]: "

# 4. Answer.
process(action='submit', session_id='proc_xxx', data='Y')

# 5. Poll again, see the secret prompt; submit the real secret (never typed
#    into a `command=` string anywhere in this flow).
process(action='poll', session_id='proc_xxx')
process(action='submit', session_id='proc_xxx', data='<the real token>')

# 6. Wait for the next prompt or completion; repeat submit for any further
#    Y/n steps (e.g. "Enable all N tools? [Y/n/select]:").
process(action='wait', session_id='proc_xxx', timeout=30)
```

Confirmed real-world result: wizard reported `✓ Saved to /opt/data/.env as
MCP_MAILFALLBACK_API_KEY` and `✓ Saved 'mailfallback' to /opt/data/config.yaml`
— i.e. the secret and the non-secret config landed in the two separate places
they belong, verifiable after the fact with a redacted grep
(`grep -i KEY_NAME /opt/data/.env | sed -E 's/=.*/=[REDACTED]/'`).

## Variant: the prompt is on a REMOTE machine, inside tmux

A long-running agent/TUI started by a daemon (Claude Code under happier, a
remote build wizard, anything spawned headlessly) can block on an interactive
prompt where you have no stdin at all — the harness that spawned it reports
something unhelpful like `"terminal exited unexpectedly"`, and the process
looks dead when it is merely waiting.

If the runner executes inside tmux (common; the spawner usually records the
target in its session metadata), the pane **is** the stdin you are missing.

### Read before you type

```bash
tmux capture-pane -p -t "$TARGET" | tail -40
tmux list-panes -t "$TARGET" -F "#{pane_dead} #{pane_pid} #{pane_current_command}"
```

`pane_dead 0` with a live `pane_current_command` means the process is alive and
blocked on input — the opposite of what "exited" implied. This capture is also
the fastest way to learn *which* prompt it is: first-run trust/consent dialogs,
theme pickers, onboarding, update notices, and expired-login screens all look
identical from outside (i.e. like a crash) and completely different in the pane.

Prefer the pane over log files. In one measured case the log path recorded in
the session metadata did not exist and the daemon log said only
`[AUTH] Using existing credentials` — while the pane showed the actual blocker
verbatim.

### Answer with send-keys — and re-capture between keystrokes

```bash
tmux send-keys -t "$TARGET" Down                       # move the selector
tmux capture-pane -p -t "$TARGET" | grep -A3 "No, exit"  # CONFIRM it moved
tmux send-keys -t "$TARGET" Enter                      # only now commit
```

**Never send a blind `Enter` into a menu.** These dialogs frequently default to
the destructive/abort option (`❯ No, exit`), so an unverified Enter kills the
session you were trying to rescue. Verify cursor position from a fresh capture
before every commit.

### Consent still applies

Answering a prompt on the user's machine is an action taken as them. A
"do you trust this folder?" dialog grants read/write/execute on that directory;
an onboarding screen may accept terms. Read the pane, tell the user exactly
what the prompt says, and get an explicit yes before `send-keys` — the same
boundary as any other write to their environment.

### After unblocking

Re-capture to confirm the tool actually started (banner, prompt line, version).
And note that the TUI recovering does **not** guarantee its control channel
recovered: in one case the pane came up healthy while the spawner still could
not deliver messages to it. If the pane is fine but the orchestrator still
cannot reach the session, stop/archive and respawn now that the prompt is
answered, rather than re-debugging the backend.

## Pitfall

If the wizard needs a value that only exists in a *different* process's
environment than your terminal shell's (e.g. this agent's own gateway
credential), fetch it in a separate step first — see the `/proc/<pid>/environ`
technique in `k8s-gitops-self-modification` — then feed it to `submit`. Don't
try to have the wizard read an env var itself unless you've confirmed the
background process actually inherits it.

## Note

Adding an MCP server this way only registers it in `config.yaml`/`.env`; the
new tools do not appear in the CURRENT running session (MCP tools are
discovered at agent startup, no hot-reload). Tell the user a restart/new
session is needed before the tools are actually callable — see `hermes-agent`
skill's native-mcp reference for the underlying mechanism.
