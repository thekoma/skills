---
name: browser-exec-chrome-setup
description: "Use when browser_exec has no Chrome to drive."
---

# Fixing browser_exec when it has no drivable Chrome

## Trigger
`browser_exec` calls fail in one of these ways:
- The harness tries to self-install the `browser-use` CLI via its bundled `uv`
  and that install fails with a DNS-ish error resolving pypi.org (a known `uv`
  resolver quirk in some sandboxes — plain `pip`/Hermes's own managed `uv`
  resolve the same host fine).
- `browser-use --doctor` (or any `browser_exec` navigation) reports no
  Chrome/Chromium available to drive, even though a `chrome-headless-shell`
  binary exists somewhere on disk (that binary alone is not sufficient —
  browser-use needs a full Chrome/Chromium it can attach DevTools Protocol to).

This is a persistent-container environment: fixes must survive a pod
restart, which means installing everything under a real mounted volume (e.g.
`/opt/data`, NOT `/tmp` or an overlay root — see the general
persistent-tooling skill for that filesystem distinction) and re-doing the
one step that does NOT persist (the running Chrome process itself).

## Fix, in order

1. **Get `browser-use` installed persistently.** Try Hermes's own managed
   `uv` first (found via `find / -iname hermes -type f -executable`, its
   sibling `uv`/`uv tool` commands) — `uv tool install browser-use` with
   THAT managed uv often succeeds even when a plain/system `uv venv` +
   `uv pip install` hits the pypi.org DNS bug, and it drops the binary in the
   standard `~/.local/bin`. If it still fails, fall back to a manual venv:
   ```
   uv venv /opt/data/venvs/browser-use
   /opt/data/venvs/browser-use/bin/python -m ensurepip
   /opt/data/venvs/browser-use/bin/python -m pip install browser-use
   ln -sf /opt/data/venvs/browser-use/bin/browser-use /opt/data/bin/browser-use
   ```
   (plain `pip` inside the venv sidesteps `uv`'s own resolver bug).

2. **Install a real Chromium persistently** — chrome-headless-shell is not
   enough:
   ```
   /opt/data/venvs/browser-use/bin/python -m pip install playwright
   PLAYWRIGHT_BROWSERS_PATH=/opt/data/home/.cache/ms-playwright \
     /opt/data/venvs/browser-use/bin/python -m playwright install chromium
   ```
   This lands the browser under `/opt/data`, so the binary survives restarts.

3. **Launch it headless as a tracked background process** (never foreground —
   Chrome doesn't exit on its own, so a foreground call just hangs):
   ```
   terminal(background=true, command='''
     /opt/data/home/.cache/ms-playwright/chromium-*/chrome-linux64/chrome \
       --headless --no-sandbox --disable-gpu --disable-dev-shm-usage \
       --remote-debugging-port=9223 \
       --user-data-dir=/opt/data/home/.cache/chrome-profile \
       about:blank''')
   ```
   Verify: `curl -s http://localhost:9223/json/version` returns JSON.
   Chrome takes a few seconds to bind the debug port after the process
   starts — an immediate curl right after launching often gets
   "Connection refused" even though the launch is fine. Don't treat that
   as a failure signal; wait ~3-5s (or retry once) before concluding the
   launch didn't work.

4. **Point browser_exec at that CDP endpoint via the CLI, never by hand-editing
   config.yaml**:
   ```
   hermes config set browser.cdp_url "http://localhost:9223"
   ```
   `hermes` may not be on PATH in a fresh terminal — locate it once with
   `find / -iname hermes -type f -executable 2>/dev/null` (commonly
   `/opt/hermes/bin/hermes`) and use the absolute path. `browser.cdp_url` is
   the top-priority override in browser_exec's backend resolution (checked
   before any cloud-provider config), so this reliably wins.

## Pitfall: config persists, the Chrome process does not
After a pod restart, `browser.cdp_url` still points at `localhost:9223` but
nothing is listening — the installed binaries and profile dir on `/opt/data`
survive, but the running process does not, and nothing supervises it back to
life automatically. Re-run step 3 to relaunch Chrome before browser_exec will
work again; there is no persistent daemon/supervisor for this yet.

## While Chrome is down, don't stall the task
`BU_CDP_URL ... unreachable after 30s: Connection refused` means the local
browser is missing, not that the target site blocked you. Get the content with
a plain `curl -sL -A "<desktop UA>"` fetch and keep working, then relaunch
Chrome afterwards. See `agent-web-access-stack` for choosing between the local
Chrome/CDP path and a fingerprint-spoofing browser for sites that genuinely
fight back.

## Verification
- `curl -s http://localhost:9223/json/version` responds.
- A `browser_exec` call (e.g. `new_tab("https://example.com"); wait_for_load();
  print(page_info())`) returns a real page title, not a launch/install error.
