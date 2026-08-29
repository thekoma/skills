# skills

Agent skills for [OpenViking](https://openviking.ai) and Claude Code: the ones
written here, and a tracked record of where every borrowed one comes from.

## Why this exists

A skill is not a dependency. It is a set of instructions an agent will read and
act on, with your credentials and your filesystem. Installing one straight from
somebody's `main` branch means their next push changes how your agent behaves,
and you find out afterwards — if at all.

So the upstreams are **pinned to a commit** in `manifest.yaml`. A daily job
checks whether they moved and opens a pull request with the compare links when
they have. Updating is a decision somebody makes, not something that happens
while you sleep.

The second reason is provenance. Skills arrive from four different repos under
three different names each — the installed name comes from the SKILL.md
frontmatter, the directory is whatever upstream called it, and the two rarely
match. `manifest.yaml` records both, plus the licence, so nobody has to guess
later who wrote what.

## What this is not

Not a marketplace. Not a mirror. Nothing here claims authorship of anybody
else's work: third-party skills keep their own licences, their `LICENSE` file
travels with them into `vendor/` as `LICENSE.upstream`, and every vendored
directory carries a `.provenance` naming the repo, the commit and the licence.

One upstream, `nraford7/Narrative-Engine`, publishes no licence at all. No
licence means no grant to redistribute, so it is recorded in the manifest and
never copied. `scripts/sync.sh` refuses to vendor any source whose licence is
missing — that rule is enforced in code, not left to good intentions.

## Layout

```
manifest.yaml     every skill, its source, its pinned ref, its licence
skills/           ours — this is the source, edit here
vendor/           third-party skills, materialised on demand (git-ignored)
scripts/sync.sh   materialise, check for drift, bump refs
```

`vendor/` is deliberately **not committed**. Committing it would make this repo
the mirror it claims not to be, would force a licence decision this project has
no standing to make, and would bury a one-line ref bump under thousands of lines
of somebody else's prose. The reviewable artefact is `manifest.yaml`: the ref
changes, the compare link is right there, and the content is one clone away.

## Using it

```sh
scripts/sync.sh            # materialise vendor/ at the pinned refs
scripts/sync.sh --check    # report drift; exit 1 if an upstream moved
scripts/sync.sh --update   # bump refs to upstream HEAD (CI does this in a PR)
```

Needs `git` and `python3` with `pyyaml`. Same script runs in CI and on a laptop;
there is no second implementation to drift out of sync.

Point OpenViking at it:

```sh
ov skills add https://github.com/thekoma/skills/tree/main/skills -s '*' -y --wait
ov skills update -y --wait
```

## Adding a skill

**Ours.** Create `skills/<name>/SKILL.md` with `name` and `description` in the
frontmatter, then add it to the `thekoma/skills` block in `manifest.yaml`.
Validate before committing:

```sh
ov skills validate skills/<name>
```

**Somebody else's.** Add a source block to `manifest.yaml` with `sourceUrl`,
`branch`, a pinned `ref`, the `license`, and one entry per skill giving `name`
and `skillPath`. `skillPath` is the path inside *their* repo and is the only
authority on where the files live — never reconstruct it from the skill name.
Then run `scripts/sync.sh` to confirm it resolves.

If the upstream has no licence, set `vendor: false`. It will be recorded and
left alone.

## Updating

The scheduled job does the watching. To do it by hand:

```sh
scripts/sync.sh --check     # what moved
scripts/sync.sh --update    # bump the refs
scripts/sync.sh             # prove the new refs still resolve
```

Then read the compare links before you merge.

## Licence

MIT, covering the contents of `skills/` — the skills written here. Everything
under `vendor/` belongs to its original author under its original licence; see
each directory's `.provenance` and `LICENSE.upstream`.
