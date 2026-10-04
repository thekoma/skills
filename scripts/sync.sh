#!/usr/bin/env bash
#
# Materialise third-party skills from manifest.yaml, or check whether their
# upstreams have moved.
#
#   scripts/sync.sh              materialise vendor/ at the pinned refs
#   scripts/sync.sh --check      report upstream drift; exit 1 if any
#   scripts/sync.sh --update     rewrite manifest.yaml refs to upstream HEAD
#
# The CI workflow runs --check on a schedule and --update inside a pull request.
# Same script both places: if it works here it works there.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/manifest.yaml"
VENDOR="$ROOT/vendor"
MODE="${1:-materialise}"

case "$MODE" in
  --check|--update|materialise) ;;
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  *) echo "unknown mode: $MODE (try --help)" >&2; exit 2 ;;
esac

command -v git >/dev/null || { echo "git is required" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "python3 with pyyaml is required" >&2; exit 2; }

# Emit one TSV line per vendorable source: source, url, branch, ref, path, license
sources() {
  python3 - "$MANIFEST" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for s in doc["sources"]:
    if not s.get("vendor"):
        continue
    if s.get("sourceType") != "github":
        continue
    print("\t".join([
        s["source"], s["sourceUrl"], s.get("branch", "main"),
        str(s["ref"]), s.get("path", "."), str(s.get("license", "")),
    ]))
PY
}

# Emit "name<TAB>dir-inside-source-repo<TAB>expected-tree-hash" per skill.
#
# Name and directory are NOT the same and must never be derived from each
# other: the installed name comes from the SKILL.md frontmatter, the directory
# is whatever upstream chose to call it. Leonxlnx/taste-skill ships
# `design-taste-frontend` in skills/taste-skill/ and `full-output-enforcement`
# in skills/output-skill/. skillPath, carried over verbatim from
# .skill-lock.json, is the only authority.
#
# The third field is skillFolderHash: the git tree SHA of the skill's folder
# at the pinned ref. `git rev-parse <ref>:<dir>` produces exactly this value,
# which is also what the GitHub contents API reports as a directory's sha.
skills_of() {
  python3 - "$MANIFEST" "$1" <<'PY'
import sys, yaml, posixpath
doc = yaml.safe_load(open(sys.argv[1]))
for s in doc["sources"]:
    if s["source"] == sys.argv[2]:
        for k in s["skills"]:
            print(k["name"] + "\t" + posixpath.dirname(k["skillPath"])
                  + "\t" + str(k.get("skillFolderHash", "")))
PY
}

# Fetch the pinned commit of a source into a fresh temp dir and print the dir.
# --depth 1 on a bare init is cheaper than a full clone and works even when
# ref is not the branch tip; some servers refuse fetch-by-sha, so fall back to
# the branch and check out.
fetch_pinned() {
  local url="$1" branch="$2" ref="$3"
  local tmp; tmp="$(mktemp -d)"
  git -C "$tmp" init -q
  git -C "$tmp" remote add origin "$url"
  if ! git -C "$tmp" fetch -q --depth 1 origin "$ref" 2>/dev/null; then
    git -C "$tmp" fetch -q --depth 50 origin "$branch" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  fi
  git -C "$tmp" checkout -q "$ref" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  echo "$tmp"
}

# Tree SHA of <dir> at <ref>, or empty when it is not a directory there.
# --verify -q matters: plain `git rev-parse ref:missing` echoes its argument on
# stdout, and that string would be written into the manifest as a hash.
# (`ref:dir^{tree}` does not work: after `:` the suffix is part of the path.)
treehash() {
  local h; h="$(git -C "$1" rev-parse --verify -q "$2:$3" 2>/dev/null)" || return 0
  [ "$(git -C "$1" cat-file -t "$h" 2>/dev/null)" = tree ] && echo "$h"
  return 0
}

# A source with vendor:false must never be materialised, whatever else changes.
# Narrative-Engine has no upstream licence; copying it would be redistribution
# without a grant. Enforced here, not merely documented in the manifest.
assert_no_unlicensed_vendoring() {
  python3 - "$MANIFEST" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
bad = [s["source"] for s in doc["sources"]
       if s.get("vendor") and str(s.get("license", "")).upper() in ("", "NONE", "UNSPECIFIED")]
if bad:
    sys.exit("refusing to vendor sources without a licence: " + ", ".join(bad))
PY
}

# Tolerant on purpose: a network blip on one source must not abort the run,
# it must be reported as "cannot read" while the others still get checked.
remote_head() { git ls-remote "$1" "refs/heads/$2" 2>/dev/null | awk '{print $1}' || true; }

materialise() {
  assert_no_unlicensed_vendoring
  rm -rf "$VENDOR"
  mkdir -p "$VENDOR"
  local n=0
  while IFS=$'\t' read -r src url branch ref path lic; do
    [ -n "$src" ] || continue
    local tmp
    tmp="$(fetch_pinned "$url" "$branch" "$ref")" || { echo "  ! $src: cannot fetch $ref" >&2; MISSING=1; continue; }

    while IFS=$'\t' read -r name reldir want_hash; do
      local from="$tmp/$reldir"
      [ -d "$from" ] || { echo "  ! $src: $name missing at $reldir" >&2; MISSING=1; continue; }
      # The manifest hash is a promise about content; verify it at the only
      # moment the content is actually here. A mismatch means the manifest was
      # edited without regenerating the hash (or the ref moved under it) - the
      # exact failure that shipped four stale hashes in PR #10 unnoticed.
      if [ -n "$want_hash" ]; then
        local got_hash
        got_hash="$(treehash "$tmp" "$ref" "$reldir")"
        if [ "$got_hash" != "$want_hash" ]; then
          echo "  ! $src: $name skillFolderHash mismatch (manifest ${want_hash:0:12}, actual ${got_hash:0:12})" >&2
          HASH_MISMATCH=1
        fi
      fi
      # A repo whose SKILL.md sits at the root vendors the entire checkout, so
      # the copy has to leave .git behind or vendor/ ends up full of nested
      # repositories. awesome-skills/code-review-skill and Narrative-Engine are
      # both shaped that way.
      mkdir -p "$VENDOR/$name"
      (cd "$from" && tar cf - --exclude .git .) | (cd "$VENDOR/$name" && tar xf -)
      # Keep the licence next to the copy so attribution travels with the files.
      for cand in LICENSE LICENSE.md LICENSE.txt COPYING; do
        [ -f "$tmp/$cand" ] && cp "$tmp/$cand" "$VENDOR/$name/LICENSE.upstream" && break
      done
      printf 'source: %s\nurl: %s\nref: %s\npath: %s\nlicense: %s\n' \
        "$src" "$url" "$ref" "$reldir" "$lic" > "$VENDOR/$name/.provenance"
      n=$((n+1))
    done < <(skills_of "$src")
    rm -rf "$tmp"
    echo "  ok $src @ ${ref:0:12}"
  done < <(sources)
  echo "materialised $n skills into vendor/"
  local rc=0
  [ "${MISSING:-0}" = "0" ] || { echo "skills missing or unfetchable; vendor/ is incomplete" >&2; rc=1; }
  [ "${HASH_MISMATCH:-0}" = "0" ] || { echo "hash mismatches found; regenerate skillFolderHash values" >&2; rc=1; }
  return $rc
}

check() {
  local drift=0
  while IFS=$'\t' read -r src url branch ref path lic; do
    [ -n "$src" ] || continue
    local head; head="$(remote_head "$url" "$branch" || true)"
    if [ -z "$head" ]; then
      echo "  ? $src: cannot read $branch" >&2; drift=1; continue
    fi
    if [ "${head:0:12}" = "${ref:0:12}" ]; then
      printf '  =  %-30s %s\n' "$src" "${ref:0:12}"
    else
      printf '  UPDATED %-26s %s -> %s\n' "$src" "${ref:0:12}" "${head:0:12}"
      # A compare link is the whole point of the review step: it turns "a ref
      # moved" into "here is what they changed".
      printf '     %s/compare/%s...%s\n' "${url%.git}" "${ref:0:12}" "${head:0:12}"
      drift=1
    fi
    # Ref drift and hash drift are different failures. The ref can be current
    # while a skillFolderHash is stale (manifest edited by hand, or a bump
    # that never regenerated the hashes - PR #10 shipped four of those and
    # --check stayed green). Fetch the pinned commit and compare each skill's
    # tree SHA against the manifest.
    local tmp
    if tmp="$(fetch_pinned "$url" "$branch" "$ref")"; then
      while IFS=$'\t' read -r name reldir want_hash; do
        [ -n "$want_hash" ] || continue
        local got_hash
        got_hash="$(treehash "$tmp" "$ref" "$reldir")"
        if [ "$got_hash" != "$want_hash" ]; then
          printf '  STALE-HASH %-23s %s: manifest %s, actual %s\n' \
            "$src" "$name" "${want_hash:0:12}" "${got_hash:0:12}"
          drift=1
        fi
      done < <(skills_of "$src")
      rm -rf "$tmp"
    else
      echo "  ? $src: cannot fetch $ref for hash check" >&2; drift=1
    fi
  done < <(sources)
  # Reference-only sources drift too; report them so a human can decide, but
  # never let them affect the exit code — we do not track their content.
  python3 - "$MANIFEST" <<'PY'
import sys, yaml, subprocess
doc = yaml.safe_load(open(sys.argv[1]))
for s in doc["sources"]:
    if s.get("vendor") or s.get("sourceType") != "github":
        continue
    out = subprocess.run(["git","ls-remote",s["sourceUrl"],
                          "refs/heads/"+s.get("branch","main")],
                         capture_output=True, text=True).stdout.split()
    head = out[0][:12] if out else "?"
    mark = "=" if head == str(s["ref"])[:12] else "UPDATED"
    print(f"  {mark:<2} {s['source']:<30} {str(s['ref'])[:12]} -> {head}  (reference only)")
PY
  return $drift
}

# Write the ref and/or skill hashes of one source in a single manifest edit.
# Args: source, new ref ("" to keep), then name=hash pairs.
write_manifest() {
  python3 - "$MANIFEST" "$@" <<'PY'
import sys
path, src, ref, *pairs = sys.argv[1:]
hashes = dict(p.split("=", 1) for p in pairs)
lines = open(path).read().split("\n")
insrc = False
skill = None
for i, l in enumerate(lines):
    t = l.strip()
    ind = l[:len(l) - len(l.lstrip())]
    if t.startswith("- source: "):
        insrc, skill = t == f"- source: {src}", None
    elif not insrc:
        continue
    elif ref and t.startswith("ref: "):
        lines[i] = f"{ind}ref: {ref}          # pinned; bump via reviewed PR"
    elif t.startswith("- name: "):
        skill = t[len("- name: "):]
    elif skill in hashes and t.startswith("skillFolderHash: "):
        lines[i] = f"{ind}skillFolderHash: {hashes.pop(skill)}"
if hashes:
    sys.exit(f"manifest has no skillFolderHash line for {src}: {', '.join(hashes)}")
open(path, "w").write("\n".join(lines))
PY
}

# Bring one source to <ref>: compute every skill's tree SHA there, and only if
# all recorded paths exist write the new ref and hashes together. On any
# failure the manifest is untouched, so the next run sees the old ref and
# retries instead of carrying a half-applied bump.
bump_source() {
  local src="$1" url="$2" branch="$3" ref="$4" newref="$5" tmp
  tmp="$(fetch_pinned "$url" "$branch" "$ref")" || { echo "  ! $src: cannot fetch $ref" >&2; return 1; }
  local pairs=() bad=0
  while IFS=$'\t' read -r name reldir want_hash; do
    local got; got="$(treehash "$tmp" "$ref" "$reldir")"
    if [ -z "$got" ]; then
      echo "  ! $src: $name missing at $reldir in ${ref:0:12}" >&2; bad=1; continue
    fi
    # No recorded hash: nothing to keep in step, presence was the check.
    [ -n "$want_hash" ] || continue
    [ "$got" = "$want_hash" ] && continue
    pairs+=("$name=$got")
    echo "  rehashed $src $name -> ${got:0:12}"
  done < <(skills_of "$src")
  rm -rf "$tmp"
  [ "$bad" = 0 ] || { echo "  ! $src: left at its old ref; fix skillPath in manifest.yaml" >&2; return 1; }
  [ -n "$newref" ] || [ "${#pairs[@]}" -gt 0 ] || return 0
  # Explicit: callers use `bump_source ... || rc=1`, which disables set -e here.
  write_manifest "$src" "$newref" "${pairs[@]}" || return 1
  [ -z "$newref" ] || echo "  bumped $src -> $newref"
}

update() {
  local rc=0
  while IFS=$'\t' read -r src url branch ref path lic; do
    [ -n "$src" ] || continue
    local head; head="$(remote_head "$url" "$branch" || true)"
    [ -n "$head" ] || { echo "  ? $src: cannot read $branch" >&2; rc=1; continue; }
    if [ "${head:0:12}" = "${ref:0:12}" ]; then
      # Ref is current, but a hash can still be stale (hand-edited manifest,
      # or an earlier bump that skipped the rehash). Fix it here too, or
      # --check keeps reporting drift that --update never resolves.
      bump_source "$src" "$url" "$branch" "$ref" "" || rc=1
    else
      bump_source "$src" "$url" "$branch" "${head:0:12}" "${head:0:12}" || rc=1
    fi
  done < <(sources)
  return $rc
}

case "$MODE" in
  materialise) materialise ;;
  --check)     echo "checking upstreams against pinned refs"; check ;;
  --update)    update ;;
esac
