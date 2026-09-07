---
name: openviking-memory-versioning
description: "Get history/diff of an OpenViking memory; judge rivals."
version: 1.0.0
author: Andrea Cervesato (thekoma), Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [openviking, memory, snapshot, versioning, git, evaluation, benchmarks]
    related_skills: [openviking-search-scoping, oss-alternative-evaluation, grounded-citations]
---

# OpenViking memory versioning

OpenViking keeps a git-like repository under its memory tree and exposes it as
`/api/v1/snapshot/{log,diff,show,commit,restore}`. This is how you answer "how
did this memory change over time", and it is also the first thing to check
before adopting any memory backend sold on version history.

## When to Use

- "How did this preference change?", "when did we learn X?", "show the history
  of this memory"
- Evaluating a memory system whose selling point is evolution chains,
  `supersedes` pointers, bi-temporality, or audit trails
- Before proposing a second memory backend alongside OpenViking

## The one thing that surprises everyone

**Only `memories/experiences/` is versioned automatically. Nothing else is.**

The automatic commit path filters hardcoded, with a single caller and no
config switch:

```python
# openviking/session/compressor_v3.py, _commit_experience_snapshot
if "/memories/experiences/" in uri and uri.endswith(".md")
```

So `preferences/`, `entities/`, `events/`, `cases/` and `identity.md` have
**zero** commits by default, and every automatic commit message reads
`Update experience memories from session commit …`. Measured on a live
instance: 1657 indexed memories, none of them with history, while a single
experiences file had 38 commits.

**But the REST endpoint has no such filter.** `POST /api/v1/snapshot/commit`
reaches `fs_service.commit()` → `viking_fs.commit()` directly and accepts any
`viking://` path. Versioning the rest of the tree is a cron job, not a patch.

## Procedure

Read credentials at runtime, never echo them:

```bash
set -a; . "${HERMES_HOME:-$HOME/.hermes}/.env"; set +a
B="${OPENVIKING_ENDPOINT}"
H=(-H "X-API-Key: $OPENVIKING_API_KEY" -H "X-OpenViking-User: hermes")
```

### History of one memory

```bash
P="viking://user/hermes/memories/preferences/<owner>/<file>.md"
curl -s "${H[@]}" --get --data-urlencode "paths=$P" --data-urlencode "limit=50" \
  "$B/api/v1/snapshot/log"
```

`paths` must be a full `viking://` URI — a relative path returns
`INVALID_URI`. It filters recursively, so passing a directory returns every
commit touching anything beneath it. Up to 32 `paths` values per call.

### What actually changed

```bash
curl -s "${H[@]}" --get --data-urlencode "path=$P" \
  --data-urlencode "from=$OLD_OID" --data-urlencode "to=$NEW_OID" \
  "$B/api/v1/snapshot/diff"
```

Returns `change_type` plus a real unified `diff_text`. This is the equivalent
of an evolution chain: it shows how a memory was rewritten, not just its
current value.

### Start versioning the rest of the tree

```bash
curl -s -X POST "${H[@]}" -H "Content-Type: application/json" \
  "$B/api/v1/snapshot/commit" \
  -d '{"message":"snapshot memories","paths":["viking://user/hermes/memories/preferences"]}'
```

Directory paths commit **recursively** (one measured call: 414 files, one
commit) and the operation is **idempotent** — an unchanged re-run returns
`{"result":"noop"}` with the previous oid and creates nothing. That is what
makes a frequent cron safe: it costs nothing when no memory changed.

## Pitfalls

- **`HEAD` is not a valid ref.** `snapshot/show?target_ref=HEAD` returns
  `NOT_FOUND: Git_ref not found: HEAD`. Use a concrete commit oid from
  `snapshot/log`, or the branch name (`main`).
- **`snapshot/show` returns commit metadata, not file content.** For the
  content of a memory use `/api/v1/content/read`; `show` gives oid, tree,
  parents, author, message.
- **`fs/ls` takes `uri`, not `path`.** Passing `path` fails with
  `query.uri: Field required`. Several sibling endpoints use `path`, so check
  per endpoint instead of assuming.
- **Zero commits for a path is a real answer, but prove the filter works
  first.** Run a control query against a path you know is in a recent commit
  (read a commit message from `snapshot/log` and reuse a URI from it). Without
  that control, a wrong URI and an unversioned file look identical.
- **The repo starts when snapshotting was enabled**, not when memories were
  created. Absence of old history is not data loss.
- **History is not wired into retrieval.** `search` offers only
  `include_provenance` (where a memory came from, not how it changed), so
  unrolling a chain means knowing the path and calling `snapshot/log`
  yourself. No tool surfaces it automatically.

## Evaluating a competing memory backend

When a product is proposed for a capability OpenViking might already have,
settle the capability question against the live API before reading any
marketing. Then apply the discipline from `oss-alternative-evaluation`, plus
what is specific to this category:

- **Vendor memory benchmarks do not reproduce.** Independent re-runs land
  ~20 points below published figures, and the gap tracks benchmark-specific
  prompt engineering rather than memory quality: dataset-specific equivalence
  rules keyed to public question ids, hidden chain-of-thought the judge never
  sees, and asymmetric judge prompts that gate WRONG behind several checks
  while letting CORRECT through. Ask for the harness and who ran it; with no
  public harness, treat the number as a claim.
- **"First among similar frameworks" hides the peer set.** Check the same
  benchmark for higher published scores from systems the vendor omitted.
- **Check reproduction and provenance, not just the score.** An unresolvable
  source repository, a licence asserted only on the marketing site, or an
  install requiring a force-unsafe flag each matter more than a leaderboard
  position.
- **Adoption is evidence.** Search the harness's own community for people
  running it. Zero practitioners alongside a strong benchmark claim is a
  finding worth reporting.
- **Weigh it as a capability trade, never a pure upgrade.** A resident sidecar
  on constrained nodes, with known silent failure modes, is a real cost. When
  the wanted capability already exists locally, the honest verdict is that the
  reason for the migration is gone — say that plainly instead of listing the
  secondary objections first.

## Verification

- [ ] Control path returns ≥1 commit before reporting any zero as meaningful
- [ ] `diff_text` inspected on a real change, not just a commit count
- [ ] Re-run of an unchanged commit returns `"result":"noop"`
- [ ] Any adopt/reject verdict names the capability question it settled first
