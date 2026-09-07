---
name: upstream-oss-contribution
description: "Use when patching a third-party repo you don't own."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [GitHub, Open-Source, Upstream, Pull-Requests, Maintainers, Fork]
    related_skills: [github-issue-to-pr, github-pr-workflow, github-code-review, github-issues]
---

# Upstream OSS Contribution

Sending a patch to a project **you do not control**. This is a different game
from pushing to your own repo: you inherit someone else's design decisions,
conventions, review taste, and CI you cannot run. `github-issue-to-pr` owns the
generic issue→PR discipline; this skill owns the constraints that only apply
when the repo belongs to someone else.

## When to Use

- Fixing a bug in a dependency/vendor project (CSI driver, library, operator).
- Turning a workaround you built locally into an upstream fix.
- Following up on an issue you (or the user) filed months ago in a third-party repo.
- Any PR where the merge button belongs to a stranger.

Do NOT use for: repos the user owns (use `github-pr-workflow`), or reviewing
someone else's PR (use `github-code-review`).

## References

- `references/maintainer-constraints.md` — worked example: reading a design
  constraint out of an issue thread and encoding it in the patch.
- `references/honest-verification-ceiling.md` — pricing the verification before
  pushing, and the exact wording for declaring what you could not test.

## Procedure

### 1. Read the whole thread, especially the maintainer's replies

`gh issue view <N> --comments`. If the API errors on Projects-classic
deprecation, fall back to
`gh api /repos/<owner>/<repo>/issues/<N> --jq .body` and
`gh api /repos/<owner>/<repo>/issues/<N>/comments --jq '.[] | "\(.user.login): \(.body)"'`.

The maintainer's comments are the **design contract**. When they have explained
why the obvious fix is wrong, your patch must visibly respect it and your PR
body must show that it does. Done when you can state, in one sentence, the
constraint the maintainer imposed.

### 2. Check whether the user already has history here

Search their prior issues and PRs on that repo
(`gh search issues --author <user> --repo <owner>/<repo>`). They may have filed
the issue, proposed a fix, or been told no. Building on their own earlier
analysis is far stronger than arriving cold, and contradicting it by accident
is embarrassing.

### 2b. Search for an existing fix before writing one

Someone may already have opened a PR for your exact bug. Search issues **and**
PRs, by symptom and by symbol, before writing a line:

```bash
gh search issues --repo <owner>/<repo> "<error string or symptom>" --include-prs --limit 15
gh search issues --repo <owner>/<repo> "<internal_function_name>" --include-prs --limit 10
```

`gh search issues` accepts only `--state open|closed` (there is no `all`); omit
the flag to get both. Searching the internal symbol you were about to patch
finds prior art that symptom wording misses, and also surfaces PRs attacking
the *same function* from a different angle.

Three outcomes, three different moves:

- **An open PR already fixes it** — do not open a duplicate. Comment on it with
  a data point it lacks (a different deployment shape, a config the author
  could not test, a case their tests would not catch). A second PR on the same
  lines gets both ignored.
- **An open PR attacks the same function from the opposite direction** — say so
  in a comment rather than opening a competing patch. Two mirror-image defects
  in one function (a false positive and a false negative on the same check) are
  one fix, and whoever is already in flight has the context.
- **Nothing exists** — proceed to step 3.

Read the review comments on any PR you find, including automated review bots.
A maintainer verdict like `keep_open salvageability=medium` with specific
objections tells you what a merged version must satisfy.

### 2c. Test the reviewer's suggested approach before endorsing it

When a reviewer prescribes a specific fix path ("derive it from function X"),
run X against your own case before agreeing. Reviewer guidance is written from
the reviewer's mental model of the code, not from execution.

Call the named function directly with your real values and compare against what
the runtime actually does:

```python
from <module> import _the_gate_function, resolve_effective_thing
print(_the_gate_function(my_real_value))   # reviewer says this is the source of truth
print(resolve_effective_thing())           # what the running system actually uses
```

When the two disagree, that divergence is the most valuable thing you can add
to the thread — it means a fix built on the prescribed path would still be
wrong for a real deployment. Trace which resolver actually handles your case
(wrap the candidates and print which one fires) so you can name it, rather than
asserting "that function isn't used".

### 3. Learn the repo's conventions before writing anything

Check what the project actually has, not what you'd expect:

```bash
python3 -c "import json; d=json.load(open('package.json')); print(d.get('scripts'))"
ls tests/ test/ spec/ 2>/dev/null
ls .github/workflows/
```

A repo whose test script is `echo "no test specified" && exit 1` with no
`tests/` directory **has no unit-test harness**. Dropping in a bespoke test
file introduces a pattern the project doesn't use and inflates the diff.
Validate your logic locally, then *describe* the verification in the PR body
instead of committing scaffolding.

Grep for an existing helper before adding one — the codebase usually already
has the primitive you need (`grep -n "getDerived\|helperName" src/`), and
reusing it keeps the diff small and idiomatic.

### 4. Write the smallest patch that fixes the class

Reuse existing helpers. Match surrounding style exactly (indentation, quoting,
comment voice). Confirm any helper signature against its source before calling
it — read the function definition, don't assume the argument order.

Syntax-check without running the project:
`node --check <file>` / `python3 -m py_compile <file>` / `go vet ./...`.

### 5. Put reasoning in review comments, not in the file

When your explanation is about *why this line looks odd* rather than *what the
code does*, post it as a **PR review comment on the line**, not as an in-file
comment. In-file comments live forever in someone else's codebase and are the
maintainer's to own; review comments answer the reviewer's question at the
moment they ask it and disappear once resolved.

Keep in-file comments to what a future reader of the code genuinely needs —
typically one short block explaining the failure mode and linking the issue.

### 6. Price the verification BEFORE you push, and tell the user

Stop at the moment the patch is ready and answer: *what would it actually take
to prove this works?* Inspect the project's harness rather than guessing:

```bash
python3 -c "import json; print(json.load(open('package.json')).get('scripts'))"
ls .github/workflows/ && grep -cE "self-hosted" .github/workflows/*.y*ml
```

Report the answer to the user before pushing, split into what you can run,
what needs their hardware, and what only the maintainer can run. This is a
decision they own: they may have a lab, may accept an untested PR, or may want
the approach reworked. Pushing first and disclosing after removes that choice.

Many upstream projects run CI on **self-hosted runners against real hardware**
with maintainer-held secrets. Those jobs do not run on fork PRs at all, and no
amount of local work substitutes for them.

### 6b. Be shamelessly honest about the ceiling

When you genuinely cannot test, say so in blunt words — not hedged, not buried.
The user's own framing for this: *we don't have the resources to test locally,
but the local analysis says this should fix it; if the maintainer is willing to
run it through their pipeline, that settles it.*

That shape works because it does three things at once:

1. **States the gap in plain language.** "I could not test this. No lab, and
   the sanity matrix needs backends and self-hosted runners I don't have."
2. **Separates verified from inferred.** List what you checked (syntax, helper
   signatures against source, logic reasoned through, formatter clean before
   and after) and then name the specific unproven claim — e.g. "whether
   `getDerivedVolumeContext(call)` resolves inside this method is unverified;
   it's called in three sibling methods so the pattern should hold, but that
   is inference, not evidence."
3. **Makes the ask.** Invite the maintainer to run it through their pipeline,
   and offer to rework or close it if the shape is wrong.

A maintainer can work with a contributor who marks the boundary of their own
knowledge. They cannot work with one who implies coverage that doesn't exist —
and they will find out at review time either way.

See `references/honest-verification-ceiling.md` for the full worked text.

If the user has a real environment and offers to test, that evidence beats any
amount of local reasoning — ask before assuming.

### 7. Open the PR against the right base, and link the issue

Fork, branch, push, then `gh pr create --repo <upstream> --head <you>:<branch>`.
Reference the issue number so the thread links. Keep the body short: problem,
why the obvious fix is wrong (citing the maintainer), what this does instead,
how it was verified, what wasn't.

## Pitfalls

- **Ignoring a constraint the maintainer already stated.** The single fastest
  way to get a PR closed. Quote it back in the PR body to prove you read it.
- **Importing your own conventions** — adding a test framework, config file, or
  directory layout the project doesn't use.
- **A large diff for a small fix.** Reviewers of unfamiliar contributors read
  every line; 60 focused lines get merged, 600 get ignored.
- **Explaining yourself in in-file comments** when a review comment is what the
  maintainer actually wants.
- **Implying integration coverage you never had.** Say what you couldn't run.
- **Never paste command output into a public comment that you did not actually
  run.** Plausible-looking numbers invented to illustrate a point (`grep -c` →
  `0`, `wc -c` → `109`) are fabrication, and they are usually wrong in a way
  that weakens the real case: the true output often makes a *stronger* argument
  than the imagined one. Execute every command in the draft, paste the real
  stdout, and re-read the draft against the terminal before posting.
- **Reporting a symptom you created yourself.** Before citing a warning or
  error in an upstream thread, confirm it reproduces in the service's own
  process rather than only in your interactive shell (see
  `k8s-secret-rollout-verification` for reading a live process's real
  environment). Exporting a variable to silence noise, then diagnosing the
  noise, produces a bug report about your own shell.
- **Pushing before telling the user what verification would cost.** Whether to
  ship an untested PR, test on their own hardware, or rework the approach is
  the user's decision. Price it and ask (step 6) rather than disclosing after
  the fact.
- **Citing a PR number in an issue comment before the PR exists.** You will
  guess wrong and link a stranger's item. Open the PR first, or patch the
  comment via `gh api -X PATCH /repos/<o>/<r>/issues/comments/<id>` and verify
  the edit landed.
- **Assuming a coding-agent CLI is available** — check auth before planning
  around it (`claude auth status`), and if it isn't set up, ask the user rather
  than silently doing the work a different way.
- Forgetting that `gh pr create` needs `--head <fork-owner>:<branch>` when the
  branch's remote tracking is missing (common after `git clone --depth 1`).

## Verification

- [ ] Issues AND PRs searched (`--include-prs`, by symptom and by symbol); no
      open PR already covers this, or a comment was added to it instead.
- [ ] Every command output quoted in the PR body or comment was actually run,
      with real stdout pasted.
- [ ] Full issue thread read; the maintainer's constraint stated in one sentence.
- [ ] The patch visibly satisfies that constraint, and the PR body says so.
- [ ] Repo conventions checked — no new test/config/directory pattern introduced.
- [ ] Existing helpers reused; signatures confirmed against source.
- [ ] Syntax check passes; formatter warnings shown to be pre-existing.
- [ ] Diff is the minimum that fixes the class.
- [ ] Verification cost priced and reported to the user BEFORE pushing.
- [ ] PR body separates what was verified from what could not be, naming the
      specific unproven claim rather than a vague disclaimer.
- [ ] Issue thread carries the same honesty as the PR body.
- [ ] Any PR/issue numbers cross-referenced in comments actually resolve.
- [ ] Line-level reasoning posted as review comments, not committed to the file.
