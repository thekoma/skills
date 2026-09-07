---
name: k8s-pod-oom-triage
description: "Diagnose a pod OOM-looping after an upgrade; verify the fix."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [kubernetes, oom, crashloop, memory, gitops, argocd, upgrade, troubleshooting]
    related_skills: [k8s-node-memory-alert-triage, k8s-gitops-self-modification, k8s-secret-rollout-verification]
---

# Triaging a single pod OOMKilling after an upgrade

## When to use

One workload (not the node) restarts repeatedly, memory climbing to its limit
and OOMKilling, usually right after an automated image bump (Renovate, Argo
Image Updater) or a manual config change. The node itself has headroom —
compare against `k8s-node-memory-alert-triage` first if you're not sure
whether the node or a single pod is the actual subject.

## Step 1 — confirm it's the pod, not the node

```bash
kubectl top node <node>                       # node has real headroom?
kubectl get pod -n <ns> <pod> -o jsonpath='{.status.containerStatuses[0].restartCount}'
kubectl describe pod -n <ns> <pod> | grep -A3 "Last State"   # reason: OOMKilled?
```

If the node itself is short on memory, this is the wrong skill — go to
`k8s-node-memory-alert-triage`.

## Step 2 — find what actually changed

Don't assume the plausible-looking recent change (a log-level flag, a config
knob) is the cause just because it's the one you can see in the diff. Check
git log / Renovate PRs for the namespace first — an unattended image bump is
often the real trigger, and the app-level flag is a red herring you'll want to
fix anyway but that doesn't explain OOM by itself.

```bash
git log --oneline -- <path-to-app-manifests> | head -5
```

## Step 3 — form ONE testable hypothesis, then verify it, don't stop at plausible

It is very easy to make a plausible-sounding fix (e.g. "debug logging was
left on, that explains the memory growth"), ship it, and declare victory
without re-observing. **Do not trust a single log_level/verbosity fix as the
root cause of an OOM until you've watched memory over time after applying
it.** Verbose logging can look like the smoking gun (huge log volume right
before the crash) while being orthogonal to the actual leak.

After any candidate fix, watch memory growth directly, not just "pod is
running now":

```bash
for i in $(seq 1 12); do
  kubectl top pod -n <ns> -l <selector> --no-headers
  kubectl get pod -n <ns> -l <selector> -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}'
  sleep 15
done
```

A fix that's actually working shows either flat memory or growth that
plateaus well under the limit — not the same linear climb as before, just
slower. If the pattern is identical (memory rises to the OOM point in roughly
the same wall-clock time), the fix didn't work, no matter how good the theory
sounded. Say so and move to the next hypothesis instead of reporting success
on a hunch.

## Step 4 — diagnose from logs before guessing

Dump the crashed container's previous logs and grep for a repeating event
that correlates with the climb, rather than staring at raw tail output:

```bash
kubectl logs -n <ns> <pod> --previous --tail=1000 > /tmp/prev.log
python3 -c "
import json
for l in open('/tmp/prev.log'):
    try:
        d = json.loads(l)
        if d.get('event') == '<suspect recurring event>':
            print(d.get('timestamp'))
    except: pass
" | wc -l
```

A recurring internal event (cache rebuild, permission recompute, provider
sync) firing dozens of times in the seconds before OOM is a much stronger
lead than "logs are noisy".

## Step 5 — the real fix vs. the workaround

When the true cause is an upstream regression (a new release genuinely uses
more baseline RAM, confirmed via release notes / GitHub issues search) rather
than something misconfigured on your side:

- **Raise the resource limit** (and proportionally the request) via GitOps —
  this is the correct immediate fix, not a hack, when the workload's real
  working set has grown. Don't feel obligated to find a "root cause" fix when
  the honest one is "this version needs more RAM now".
- Still land any orthogonal cleanup found along the way (e.g. a stray debug
  log level) — it's worth doing, just don't credit it with fixing the OOM if
  the plateau data doesn't back that up.
- Note the upstream issue/version in the commit message so a future OOM on
  the same app isn't re-diagnosed from scratch.
- Watch for a genuine plateau (5+ minutes, memory oscillating in a narrow
  band well under the new limit, 0 further restarts) before declaring it
  fixed to the user.

## Step 6 — answering a later "how has it been since?" follow-up

When the user asks days later whether a previously "resolved" OOM has caused
more trouble, do not just check current live health (`kubectl top pod`,
restart count) and report "fine, 0 restarts". Your own earlier "resolved"
message can itself have been premature — a first fix attempt that looked
sufficient at the time but wasn't. Reconstruct the **full** timeline instead
of trusting the last thing you told the user:

```bash
git log --pretty="%h %ad %s" --date=format:"%Y-%m-%d %H:%M" -- <path-to-app-manifests>
```

If that shows several more commits after the one you called "the fix" —
same app, memory limit bumped again, a different mechanism added (e.g. glibc
arena tuning after a log-level theory didn't hold) — the honest answer is the
whole iteration chain, not just current green state. Report it as: what the
first fix addressed, what it missed, what actually closed it, and since when
it's been stable. A real case (Authentik, 2026-09-02): a 07:59 fix
(log_level + 1536Mi) was declared "resolved", but 5 more commits followed the
same day (2Gi → 3Gi → 4Gi, `MALLOC_ARENA_MAX` cap, node move) before it
actually stopped OOMing — the root cause was glibc arena retention under a
real admin-UI browse spike, not the log level.

## Pitfalls

- **Declaring victory right after a config push, before the memory curve has
  had time to repeat.** The old crash cadence might be 90 seconds; watch for
  at least 2-3x that window past the push.
- **Trusting your own past "resolved" report as the end of the story.** When
  asked for a status update later, re-check the commit history since that
  report, not just current live metrics — a fix can have been iterated on
  further without you being told, especially by the user directly via
  GitOps commits outside the session.
- **Conflating "a flag that looked responsible for noise" with "the fix".** If
  memory still climbs to the limit on the same clock, revert or extend the
  hypothesis — don't report the noisy flag as resolved.
- **Not checking node headroom before touching resource limits** — raising a
  pod's memory limit on a node that's itself tight just moves the OOM to the
  node level or evicts a neighbor.

## Verification

- [ ] Confirmed OOM is pod-level (node had headroom), or redirected to
      `k8s-node-memory-alert-triage`.
- [ ] Root-cause hypothesis backed by a recurring log event or an upstream
      issue/release-note citation, not just plausibility.
- [ ] Memory observed post-fix for multiple crash-cycle windows, restart
      count confirmed flat (not just "pod Running now").
- [ ] If the fix is a raised limit due to a genuine upstream regression, said
      so plainly instead of dressing it up as a root-cause fix.
