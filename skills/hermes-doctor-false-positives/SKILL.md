---
name: hermes-doctor-false-positives
description: "Diagnose false hermes doctor failures on gateway deploys."
version: 1.0.0
author: Andrea Cervesato (thekoma), Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [hermes, doctor, diagnostics, litellm, gateway, containers, false-positive]
    related_skills: [hermes-agent, upstream-oss-contribution]
---

# `hermes doctor` false positives on gateway / container deploys

Two `doctor` checks report failures on installs that work perfectly. Both are
upstream bugs, not local misconfiguration.

## When to Use

- `hermes doctor` shows red rows on an install whose every LLM call succeeds
- Hermes runs behind LiteLLM, OpenRouter, or any relay set via `base_url`
- Hermes runs in a container with secrets injected as environment variables
- Before "fixing" a profile that a diagnostic claims is broken

## Find a control case before believing the diagnosis

Run `doctor` on a SECOND profile or install. If the same red rows appear there
too, the profile under suspicion is not the cause. A diagnostic that fails
identically everywhere is describing itself, not your config.

## Check your own shell first

Agent tool shells often STRIP credential env vars (`ANTHROPIC_API_KEY`,
`ANTHROPIC_BASE_URL`, ...) from the environment they hand to commands. Running
`hermes ...` by hand there produces warnings the real gateway never emits:

```
Config ref '${env:ANTHROPIC_BASE_URL}': ANTHROPIC_BASE_URL is not set
```

That warning is an artifact of the tool shell. Before reporting any env-related
diagnostic, check whether it appears in the gateway's OWN log
(`$HERMES_HOME/logs/gateways/<profile>/current`) and read the real process
environment:

```bash
tr '\0' '\n' < /proc/<gateway-pid>/environ | grep -c '^ANTHROPIC_API_KEY='
```

To reproduce `doctor` as the gateway sees it, build the env dict from `/proc`
and pass it to a subprocess. Never `export FOO=x` to silence the noise: that
contaminates the evidence and invents a second fake problem to chase.

## `Anthropic API (invalid API key)` with a working relay

`_probe_anthropic()` in `hermes_cli/doctor_connectivity.py` hardcodes
`https://api.anthropic.com/v1/models` and ignores the configured `base_url`.
With a relay it presents the relay-issued key to Anthropic direct, which
answers 401. The runtime is unaffected and keeps using the relay:

```
runtime  POST <relay>/v1/messages          -> 200
doctor   GET  api.anthropic.com/v1/models  -> 401 authentication_error
```

Name the side effect to the user: the probe LEAKS the gateway key to a third
party on every `doctor` run. That matters more than the wrong red row.

Upstream: PR #73160 (open; automated review verdict `keep_open
salvageability=medium`).

## `No API key found in ~/.hermes/.env` with keys in the environment

`_has_provider_env_config()` (`hermes_cli/doctor_config.py`) is a substring
search over the `.env` FILE against `_PROVIDER_ENV_HINTS`. Container deploys
inject secrets into the process environment (Vault, K8s Secrets) and never
write them to `.env`, so the check reports missing keys on a working install.

Its remediation (`run hermes setup`) would write a managed secret to disk.
Wrong direction: tell the user to ignore it.

The mirror bug (a commented placeholder like `# OPENROUTER_API_KEY=` counting
as a configured key) is upstream PR #89052. Same function, opposite direction,
one fix.

## Runtime base_url resolution does NOT go through the Anthropic gate

Load-bearing when reasoning about either bug, and the thing reviewers get wrong.

`_anthropic_base_url_override_ok()` (`hermes_cli/runtime_provider.py`) returns
`False` for a bare LiteLLM URL (no `.anthropic.com`/`.claude.com`/`.azure.com`
host, no `/anthropic` suffix), yet the runtime happily uses that URL with
`api_mode: anthropic_messages`. Resolution lands in
`_resolve_runtime_from_pool_entry` -> `_pool_entry_mode_and_url`, never in
`_anthropic_env_runtime`, so the override gate is not consulted at all.

Consequence: do not treat that gate as "the runtime-effective path" when
building or reviewing a probe fix. A probe derived from it would report a URL
the runtime never calls. `resolve_runtime_provider()` (no args, reads
`$HERMES_HOME`) returns the effective `provider`, `api_mode`, `base_url` and
key source together, and is the honest comparison target:

```python
import sys, os
sys.path.insert(0, HERMES_SOURCE_DIR)    # where the hermes package lives
os.environ["HERMES_HOME"] = HERMES_HOME  # profile dir holding config.yaml
from hermes_cli.runtime_provider import resolve_runtime_provider
print(vars(resolve_runtime_provider()))
```

To find which resolver actually fires, wrap the candidates and print on a
truthy return rather than asserting from the call graph.

## Pitfalls

- Treating a red `doctor` row as ground truth on a non-default deployment.
  Probe an endpoint yourself before changing config.
- Silencing an env warning with `export`, then diagnosing the silence.
- Concluding "the gate rejects our URL, so the runtime must too". Test both.

## Verification

- [ ] Same red rows reproduce on a second profile (rules out local config)
- [ ] Warning absent from the gateway's own log, present only in the tool shell
- [ ] A real call through the configured `base_url` returns 200
- [ ] Provider key confirmed present in the gateway's `/proc/<pid>/environ`
