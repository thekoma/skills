---
name: k8s-node-memory-alert-triage
description: "Triage a node memory/page-fault alert: real or swap?"
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [kubernetes, memory, swap, psi, page-faults, prometheus, alerting, node, qemu, troubleshooting]
    related_skills: [iscsi-orphan-session-triage, k8s-node-disk-capacity, k8s-gitops-self-modification, agent-memory-backends]
---

# Triaging a node memory alert

## When to Use

A node-level memory alert fires and you must decide whether it is real:

- `NodeMemoryMajorPagesFaults` — *"N major page faults per second … Please check
  that there is enough memory available at this instance."*
- `NodeMemoryHighUtilization`, `MemoryPressure`, host feels sluggish.
- A workload was recently deployed/resized and the alert is being attributed
  to it.

Not this skill: high **system CPU** with no container accounting for it (see
`iscsi-orphan-session-triage`), disk-full conditions
(`k8s-node-disk-capacity`), or a single **application pod** OOMKilling /
CrashLoopBackOff after an image upgrade while the node itself has headroom —
that is `k8s-pod-oom-triage`.

## The alert text is a guess, not a diagnosis

`NodeMemoryMajorPagesFaults` tells you pages are being read **from disk**. It
appends "check that there is enough memory" as boilerplate. Major faults have
several causes and only one of them is memory exhaustion:

| Cause | Signature |
|---|---|
| Genuine memory pressure | `MemAvailable` low **and** PSI `memory` > 0 |
| Swap-in from over-eager swapping | PSI `memory` ≈ 0, PSI `io` high, swap in use |
| Cold page-cache / large sequential read | swap untouched, `Cached` climbing |
| A process starting up | short-lived spike, correlates with a start event |

**PSI is the discriminator.** Read both:

```bash
cat /proc/pressure/memory   # some avg10=0.00 → NOBODY is waiting on memory
cat /proc/pressure/io       # some avg10=19.72 → the disk is the contended resource
```

`memory avg10=0.00` with `io avg10` in the double digits means the node is not
short of memory. It is *reading from disk*, and the interesting question is why.
Quote both numbers to the user — it is the one measurement that turns
"add more RAM" into an actual answer.

## Step 1 — Do not blame the thing that changed most recently

The strongest pull is to attribute the alert to whatever was just deployed,
migrated, or resized. Check it and rule it out explicitly *before* saying
anything, because the user will assume the same and a wrong confirmation is
expensive to walk back.

```bash
kubectl top nodes
kubectl top pods -A --no-headers | sort -k4 -hr | head -12
```

Then check the node's real headroom. In one session a memory alert landed hours
after a memory-motivated migration; the new service was 9th by RSS, the node had
17 GB of 65 GB available, and the culprit was a VM that had nothing to do with
it. "The thing you are worried about is not involved, here is what is" is a
better opening than a hedge.

## Step 2 — Swap: is any in use, and whose?

Container RSS does not show swap. Get it from the host:

```bash
grep -E "^Swap(Total|Free|Cached)" /proc/meminfo
```

Per-process, via a privileged `hostPID` pod (see `iscsi-orphan-session-triage`
Step 2 for the pod shape — `nodeName`, `hostPID: true`, `/proc` mounted):

```bash
for P in /proc/[0-9]*; do
  S=$(grep -s "^VmSwap:" $P/status | awk '{print $2}')
  [ -n "$S" ] && [ "$S" -gt 0 ] 2>/dev/null && echo "$S $(cat $P/comm)"
done | sort -rn | head -15 | awk '{printf "  %8.1f MB  %s\n", $1/1024, $2}'
```

Then read `vm.swappiness`. **`swappiness = 100` on a node with free memory is
itself the finding**: the kernel evicts cold anonymous pages pre-emptively, with
no pressure to justify it, and every later touch is a major fault. That is a
tuning value, not a capacity problem, and it is fixed with a sysctl rather than
with RAM.

## Step 3 — Attributing swap to a VM guest

On hyperconverged nodes the top swapper is often `qemu-system-x86`. Resolve
which guest:

```bash
tr '\0' '\n' < /proc/<pid>/cmdline | grep "guest=" | head -1 | sed 's/.*guest=//;s/,.*//'
```

Two readings that matter:

- **`RSS + Swap ≈ the guest's configured memory`** means the guest has touched
  *all* the RAM it was given at some point. That is normal for services that
  preallocate — an LDAP entry cache (389-ds), a JVM heap (Dogtag CA) — and it
  makes the guest the natural swap victim: lots of allocated-but-cold anonymous
  memory. "It only runs four calm services" does not contradict this; the
  allocation happens at startup regardless of traffic.
- **`virtio-balloon` being present does not mean it can help.** The balloon
  reclaims memory the *guest* considers free. Memory held by a preallocated
  cache or a JVM heap is not free inside the guest, so the balloon has nothing
  to give back.

Compare against a sibling VM on the same host. One guest deep in swap while
another with similar size sits almost entirely resident points at that guest's
allocation pattern, not at the host being short.

## Step 4 — /proc field-22 is starttime, NOT uptime

The trap that produced a false "the VM was restarted 38 seconds ago" in one
session, and alarmed the user into asking who had rebooted their identity
provider. Nobody had.

Field 22 of `/proc/<pid>/stat` is **starttime**: clock ticks *after boot* at
which the process started. It is not age.

```bash
START=$(awk '{print int($22/100)}' /proc/<pid>/stat)   # seconds after boot
UP=$(awk '{print int($1)}' /proc/uptime)               # host uptime
echo "process age: $((UP - START)) s"                  # THIS is the age
```

A tiny field-22 value means the process started *early in the host's boot* —
the opposite of recently. Before reporting any restart, take the cheapest
confirmation available:

- **Did the PID change?** A restarted process gets a new PID. Same PID across
  two observations = it never went away. This alone refutes a restart claim and
  costs nothing.
- Cross-check with a start event (`journalctl`, libvirt log, container
  `startedAt`) rather than inferring from a counter.

More generally: **any derived number that implies an event happened — a
restart, a crash, a spike — deserves one independent confirmation before it
reaches the user.** A wrong "something restarted" sends them looking for an
intruder in their own infrastructure.

## Step 5 — Recommend, don't execute, on a control-plane node

Where the node is also etcd/control-plane/storage (a common homelab
consolidation), the fix is usually small but the blast radius is not:

- `vm.swappiness` 100 → 10 — stop pre-emptive swapping while free memory exists.
- `swapoff -a && swapon -a` — pull already-swapped pages back into RAM. Needs
  enough free memory to absorb them, and spikes I/O briefly; schedule it.
- Per-guest `memory.swap.max=0` in a cgroup if only one workload should be
  exempt.
- Right-sizing the guest is the deeper fix, but measure real in-guest usage
  first or you trade swap for an in-guest OOM.

Say which node role makes this sensitive and let the user pick the moment.
Landing a sysctl on the node that holds etcd and every iSCSI volume is their
call, not a detail to slip into a diagnosis.

## Pitfalls

- **Reading a `VmSwap` value and reporting it as "currently swapping".** A
  swapped page sitting untouched costs nothing. Accumulated swap over days is a
  different story from active thrashing — distinguish them with PSI `io` and
  the fault *rate*, not with the swap total.
- **Trusting the alert's own suggested cause.** Prometheus alert annotations are
  written for the common case; check the specific one.
- **node-exporter labels are `instance=<ip>:9100`**, not the node name — map the
  IP with `kubectl get nodes -o wide` before assuming which host fired.
- **Clean up privileged debug pods**, every time.
- **A `restricted` PodSecurity namespace rejects a casual debug pod**; use
  `kube-system` with `tolerations: [{operator: Exists}]` and `nodeName` pinned,
  or supply the full restricted security context.
- **Don't defend the first reading when the user reacts with surprise.** "Chi ha
  riavviato?" was the signal that a derived number was wrong. Surprise from
  someone who knows their infrastructure is evidence — re-derive before
  explaining.

## Verification

- [ ] PSI `memory` and `io` both quoted, and the discriminator stated.
- [ ] `MemAvailable` vs `MemTotal` given, so "not enough memory" is confirmed or
      refuted with a number.
- [ ] Top swap consumers named as *processes/guests*, not as "the node".
- [ ] `vm.swappiness` read before recommending any tuning.
- [ ] Any claimed restart backed by a PID change or a start event, never by
      field 22 alone.
