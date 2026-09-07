# Declaring an honest verification ceiling

Worked example from a `democratic-csi` PR (issue #536 → PR #569): a 58-line
fix to iSCSI session cleanup, written with no ability to run the project's
integration suite.

## Why this matters more than it looks

The temptation is to let "syntax checks pass and the logic is sound" quietly
stand in for "this works". It reads as confidence. To a maintainer who then
finds the gap at review time, it reads as either sloppiness or spin — and it
costs you the benefit of the doubt on every future PR.

The user's framing, which is the right instinct: *be shamelessly honest — we
don't have the resources to test locally, but analysing the local behaviour
says this could fix it; if the maintainer is kind enough to run it through
their test pipeline, that solves the problem.*

## Step 1 — Price the verification before pushing

Find out what the project's harness actually is, then tell the user what each
tier costs:

```bash
python3 -c "import json; print(json.load(open('package.json')).get('scripts'))"
ls tests/ test/ spec/ 2>/dev/null
grep -cE "name: csi-sanity|self-hosted" .github/workflows/*.y*ml
```

Findings in that session:

- `npm test` was `echo "Error: no test specified" && exit 1`, no `tests/` dir —
  so any test file would import a pattern the project doesn't have.
- 12 `csi-sanity` jobs on **self-hosted runners** against real Synology/TrueNAS
  hardware with maintainer secrets — unrunnable by a contributor, and skipped
  entirely on fork PRs.

Report as three tiers: **what I can run here**, **what needs your hardware**,
**what only the maintainer can run**. Let the user choose. In that session the
user chose to ship with a disclosure rather than test on their production
cluster — their call to make, not one to assume either way.

## Step 2 — Verify everything that IS cheap

Being unable to integration-test is not licence to skip the free checks:

```bash
node --check src/driver/index.js            # syntax
grep -n "async function retry" src/utils/general.js   # confirm helper signature
npx prettier --check src/driver/index.js    # formatting
```

Run the formatter check **on a stash of your change too**, so you can say the
warning is pre-existing rather than yours:

```bash
git stash && npx prettier --check <file>; git stash pop
```

## Step 3 — Write the disclosure

The structure that worked, reusable verbatim:

```markdown
## Honesty about verification

**I could not test this.** No lab to reproduce against, and the csi-sanity
matrix needs storage backends and self-hosted runners I do not have.

What I actually verified:
- `node --check` passes
- `GeneralUtils.retry(retries, delay, code)` signature matches usage
- the decision logic reasoned through by hand, including the multi-lun guard
- prettier reports the same pre-existing warning on this file before and after

What I did **not** verify: the runtime path. Whether
`getDerivedVolumeContext(call)` resolves correctly inside `NodeUnstageVolume`
is unproven. It is already called in three other node methods, so the pattern
should hold, but that is inference, not evidence.

Analysis of the local behaviour says this should fix it. If you are willing to
run it through your test pipeline, that would settle whether it actually does.
Happy to rework the approach, split it differently, or close it if the shape
is wrong.
```

Note the three moves: blunt statement of the gap, an itemised split between
checked and inferred (naming the *specific* unproven call, not a vague
disclaimer), and an explicit ask plus an offer to rework.

## Step 4 — Post the same honesty in the issue thread

The issue is where the maintainer's context lives. Add the evidence that was
missing from the original report — in that session, a timestamped lifecycle
trace proving the first login failure landed one second *before* the destroy,
with no logout ever logged — then repeat the verification ceiling. Do not let
the PR body carry a caveat the issue thread lacks.

## Pitfall: referencing a PR number before the PR exists

Writing "#560 implements the fallback" in the issue comment *before* opening
the PR produced a wrong number (the PR landed as #569) and a link to an
unrelated item in a busy repo.

Either open the PR first and then comment, or patch the comment afterwards:

```bash
CID=$(gh api /repos/<owner>/<repo>/issues/<N>/comments \
  --jq '[.[] | select(.user.login=="<you>")] | last | .id')
BODY=$(gh api /repos/<owner>/<repo>/issues/comments/$CID --jq '.body' \
  | sed 's|#560|#569|')
gh api -X PATCH /repos/<owner>/<repo>/issues/comments/$CID -f body="$BODY"
```

Verify the edit landed rather than assuming:

```bash
gh api /repos/<owner>/<repo>/issues/comments/$CID --jq '.body' | grep -oE "#[0-9]+ implements"
```
