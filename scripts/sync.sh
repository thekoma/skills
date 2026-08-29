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

# Emit "name<TAB>dir-inside-source-repo" for each skill of a source.
#
# The two are NOT the same and must never be derived from each other: the
# installed name comes from the SKILL.md frontmatter, the directory is whatever
# upstream chose to call it. Leonxlnx/taste-skill ships `design-taste-frontend`
# in skills/taste-skill/ and `full-output-enforcement` in skills/output-skill/.
# skillPath, carried over verbatim from .skill-lock.json, is the only authority.
skills_of() {
  python3 - "$MANIFEST" "$1" <<'PY'
import sys, yaml, posixpath
doc = yaml.safe_load(open(sys.argv[1]))
for s in doc["sources"]:
    if s["source"] == sys.argv[2]:
        for k in s["skills"]:
            print(k["name"] + "\t" + posixpath.dirname(k["skillPath"]))
PY
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
    local tmp; tmp="$(mktemp -d)"
    # Fetch the pinned commit only. --depth 1 on a bare init is cheaper than a
    # full clone and works even when ref is not the branch tip.
    git -C "$tmp" init -q
    git -C "$tmp" remote add origin "$url"
    if ! git -C "$tmp" fetch -q --depth 1 origin "$ref" 2>/dev/null; then
      # Some servers refuse fetch-by-sha; fall back to the branch then check out.
      git -C "$tmp" fetch -q --depth 50 origin "$branch"
    fi
    git -C "$tmp" checkout -q "$ref"

    while IFS=$'\t' read -r name reldir; do
      local from="$tmp/$reldir"
      [ -d "$from" ] || { echo "  ! $src: $name missing at $reldir" >&2; continue; }
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

update() {
  while IFS=$'\t' read -r src url branch ref path lic; do
    [ -n "$src" ] || continue
    local head; head="$(remote_head "$url" "$branch" || true)"
    [ -n "$head" ] || continue
    [ "${head:0:12}" = "${ref:0:12}" ] && continue
    python3 - "$MANIFEST" "$src" "${head:0:12}" <<'PY'
import sys, re
path, src, new = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().split("\n")
inblk = False
for i, l in enumerate(lines):
    if l.strip().startswith("- source: "):
        inblk = l.strip() == f"- source: {src}"
    elif inblk and l.strip().startswith("ref: "):
        indent = l[:len(l) - len(l.lstrip())]
        lines[i] = f"{indent}ref: {new}          # pinned; bump via reviewed PR"
        inblk = False
open(path, "w").write("\n".join(lines))
PY
    echo "  bumped $src -> ${head:0:12}"
  done < <(sources)
}

case "$MODE" in
  materialise) materialise ;;
  --check)     echo "checking upstreams against pinned refs"; check ;;
  --update)    update ;;
esac
