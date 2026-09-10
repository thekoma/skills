---
name: version-line-ordering
description: "Use when a version bump looks major; check dates first."
version: 0.1.0
license: MIT
platforms: [linux, macos]
---

# A higher version number can be older

Use before accepting, merging or hand-applying any dependency bump where the
new version crosses a major boundary, and whenever a project appears to have
two concurrently-maintained major lines.

## The failure

A project that spins out of a parent, or renumbers for any reason, leaves two
live-looking release lines where **the higher one is abandoned**. Every semver
comparator reads the higher number as newer, so:

- a dependency bot automerges the "upgrade" and it is a downgrade
- a reviewer reasoning "the higher major must be current" re-does it by hand
  after someone reverts it

Both happen, in that order, and the second is worse because it removes the pin
that was protecting the repo.

Real instance: agentgateway's Kubernetes controller shipped inside kgateway and
inherited its numbering, reaching `v2.2.1` (2026-02-26). In March 2026 the
project split out and **restarted at v1.0.0** to match its standalone binary.
`v1.5.0` is dated 2026-08-27. So `1.5.0 -> 2.2.1` is a six-month downgrade onto
a dead line, and nothing in the version strings says so.

## The check

Resolve order by **publish date**, never by the number. One command:

```bash
# GHCR / OCI chart or image (note the %2F for a nested path)
gh api "users/<org>/packages/container/<name>/versions" --paginate \
  --jq '.[]?|select(.metadata.container.tags|length>0)
        |"\(.created_at[:10])  \(.metadata.container.tags|join(","))"' \
  | grep -vE 'alpha|beta|rc|main|dev|sha256' | sort -r | head -15

# GitHub releases
gh api "repos/<org>/<repo>/releases?per_page=20" \
  --jq '.[]|"\(.published_at[:10])  \(.tag_name)"'
```

Two lines interleaved by date, rather than one strictly newer than the other,
is the signal. A renumbering is announced in a **release blog post**, not in the
tag list — search for one whenever the dates look wrong.

## Recording the decision

A pin below a major (`allowedVersions: "<2.0.0"`) is normally debt to be repaid
by migrating. When the higher major is genuinely the older line, that pin is
**permanent** and the distinction must survive review:

- put the **dates** in the pin's description, not just "breaks auth" — the
  numbers argue the opposite and a future reader will re-derive the wrong
  conclusion from them
- name the renumbering event and link the announcement
- say what would justify removing it ("only if upstream passes 2.0.0 again on
  the new line")

A pin whose description explains only the *symptom* is the one that gets
removed.

## Related traps

- **Same version number, different content.** A project publishing to both an
  `https://` Helm repo and an OCI registry can serve different payloads under
  one version: the git tag is old, `main` kept receiving fixes, and the OCI tag
  was re-published from a later commit. Compare a hash of the resolved artifact,
  not the version string.
- **A tag listing is paginated and truncates in silence.** `GET
  /v2/<repo>/tags/list` returns a capped page with no marker that more exist,
  so a version can be entirely absent from the response while being real.
  Resolve a specific version directly rather than inferring absence from a list.
- **Chart version and app version are independent.** A chart's `appVersion` and
  the image tag its controller actually deploys can differ by a whole line;
  read the rendered manifest, not the chart metadata.

## Verification

- [ ] Publish dates compared, not version strings
- [ ] If two major lines exist, the renumbering announcement found and read
- [ ] Any pin's description carries the dates and the removal condition
