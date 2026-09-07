---
name: k8s-secret-rollout-verification
description: "Verify a K8s pod actually reloaded an updated Secret or env."
version: 1.0.0
author: curator
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [kubernetes, vault, secrets, configmap, rollout, debugging, env]
---

# K8s Secret/Config Rollout Verification

Class of task: you (or the user) changed a Vault secret, ConfigMap, or a mounted `.env` file that a running K8s Deployment consumes as environment variables — and you need to know whether the **live pod** actually has the new value, not just whether the write succeeded.

The core trap: **writing the secret/config is not the same as the pod having it.** Env vars are read once at container start (by the entrypoint / init system), not hot-reloaded. A `vault kv put` or `git push` that updates the source does nothing to an already-running pod.

## Step 1 — Detect staleness before touching anything

Compare the pod's start time to the config/secret's modification time:

```bash
kubectl get pod -n <ns> -l app.kubernetes.io/name=<app> -o jsonpath='{.items[0].status.startTime}'
# vs
vault kv get -format=json secret/<path> | jq '.data.metadata.created_time'   # Vault KV v2
# or, for a file mounted from a synced .env:
kubectl exec -n <ns> deploy/<app> -- stat /path/to/.env | grep Modify
```

If the pod started **before** the config changed, it is running on stale values — full stop, don't debug the application logic yet, restart first.

## Step 2 — Read the value the live process actually sees (not the exec shell's view)

`kubectl exec ... -- env` shows the environment of the shell `exec` just spawned — which by default runs as the container's default user (often `root`, e.g. under s6-overlay, tini, dumb-init wrappers). If the real application process runs as a **different, unprivileged user** (common pattern: an init system starts as root then `su`/`gosu`/`s6-setuidgid`'s into an app user), that process can have a **completely different environment** than your exec shell — including env vars set by scripts that ran only in the app-user's boot sequence, or files (`.env`) that get sourced only under that user's context.

Diagnose properly:

```bash
# 1. Find the real server process (not pid 1's wrapper)
kubectl exec -n <ns> deploy/<app> -- ps aux
# look for the actual long-running app binary, note its PID and USER column

# 2. /proc/<pid>/environ is owner-only (-r--------) — if the process runs as
#    a non-root user, a root exec shell CANNOT read it directly:
kubectl exec -n <ns> deploy/<app> -- cat /proc/<PID>/environ   # permission denied if owned by another user

# 3. Read it (or reproduce the test) AS that user instead:
kubectl exec -n <ns> deploy/<app> -- su <appuser> -c 'env | grep -i <VAR>'
# or, for a live network/API test using that user's actual env:
kubectl exec -n <ns> deploy/<app> -- su <appuser> -c 'curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOKEN" "$URL"'
```

Don't conclude "the env var is missing" from a root exec shell reporting empty — check under the actual runtime user first.

## Step 3 — Force the reload and confirm the NEW pod, not the restart command's exit code

```bash
kubectl rollout restart deployment/<app> -n <ns>
kubectl rollout status deployment/<app> -n <ns> --timeout=90s
```

A `rollout restart` can be interrupted by an unrelated session/gateway hiccup before it finishes. **Never assume it completed** — after any interruption, re-check real state instead of re-running the old command blindly:

```bash
kubectl get pods -n <ns> -o wide          # confirm a NEW pod name/age exists
kubectl rollout status deployment/<app> -n <ns> --timeout=15s
```

Then repeat Step 2 against the **new** pod to confirm the value actually changed (e.g. compare length/prefix of a secret before/after — never print a full secret to logs or chat).

## Step 4 — Prove it with a real functional call

Don't stop at "the env var is now set" — that only proves the value loaded, not that it works. Finish with one real request through the actual code path (an authenticated curl to the exposed endpoint, a login redirect check, etc.) and read the actual response code/body.

## Pitfalls

- **Never copy a truncated/ellipsized value (`abc...xyz`) into a real secret.** If a tool or terminal output shows a secret abbreviated with `...`, that is a display artifact, not the real value — copying it corrupts the secret and silently breaks whatever consumes it (seen breaking an OIDC `client_secret` in production). Always source full values from the origin (password manager, `openssl rand`, provider UI), never from truncated echoes.
- **A stale `.env`/ConfigMap sync agent** (e.g. a Vault-secrets sidecar writing to a shared file) can update the file on disk seconds or minutes after you think you changed it — always check the file's own mtime, don't assume your write landed instantly.
- **Don't declare success from the restart command's exit code alone** — `rollout status` timing out, a killed session, or a race with a sync agent can all leave you with a pod that looks new but still has old values loaded.
