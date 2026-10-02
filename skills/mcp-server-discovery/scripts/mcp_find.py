#!/usr/bin/env python3
"""Fan-out search for MCP servers across the public registries, then enrich
with GitHub repo health. Stdlib only. IPv4 forced (IPv6 egress blocked here).

Usage:
  mcp_find.py <term> [<term> ...] [--limit N] [--no-github] [--json]

Each term is searched separately (registries match differently: the official
registry does a NAME substring match only, so pass synonyms: kubernetes k8s).

Sources (all keyless):
  official  registry.modelcontextprotocol.io /v0.1/servers?search=&version=latest
  github    api.mcp.github.com /v0.1/servers   (10 req/window, carries stars+readme)
  smithery  registry.smithery.ai /servers?q=   (full-text, useCount, verified, remote)
  docker    github.com/docker/mcp-registry servers/<name>/server.yaml (curated, ~330)
Enrichment: `gh api repos/<o>/<r>` -> stars, pushed_at, archived, license, open issues.
"""
import json, socket, subprocess, sys, urllib.parse, urllib.request

# force IPv4
_orig = socket.getaddrinfo
socket.getaddrinfo = lambda h, p, f=0, *a, **k: _orig(h, p, socket.AF_INET, *a, **k)

UA = {"User-Agent": "mcp-find/1.0", "Accept": "application/json"}


def get(url, timeout=30):  # official registry measured at 11-20s
    try:
        req = urllib.request.Request(url, headers=UA)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except Exception as e:  # noqa: BLE001
        return {"_error": f"{type(e).__name__}: {e}"}


def repo_of(url):
    """owner/repo only for a real github.com URL. Substring matching would let
    https://evil.example/github.com/trusted/x borrow trusted/x's health."""
    if not url:
        return None
    try:
        u = urllib.parse.urlsplit(url.strip())
    except ValueError:
        return None
    if u.scheme not in ("http", "https") or (u.hostname or "").lower() not in ("github.com", "www.github.com"):
        return None
    p = [x for x in u.path.split("/") if x]
    return f"{p[0]}/{p[1].removesuffix('.git')}" if len(p) >= 2 else None


def official(term, limit):
    d = get("https://registry.modelcontextprotocol.io/v0.1/servers?"
            + urllib.parse.urlencode({"search": term, "version": "latest", "limit": limit}))
    if "_error" in d:
        return [], d["_error"]
    out = []
    for s in d.get("servers", []):
        sv = s["server"]
        out.append({
            "src": "official", "name": sv["name"], "desc": sv.get("description", ""),
            "repo": repo_of((sv.get("repository") or {}).get("url")),
            "version": sv.get("version"),
            "packages": sorted({p.get("registryType") for p in sv.get("packages", [])} - {None}),
            "remote": [r.get("type") for r in sv.get("remotes", [])],
        })
    return out, None


def github_registry(term, limit):
    d = get("https://api.mcp.github.com/v0.1/servers?"
            + urllib.parse.urlencode({"search": term, "limit": limit}))
    if "_error" in d:
        return [], d["_error"]
    out = []
    for s in d.get("servers", []):
        sv = s["server"]
        gh = sv.get("_meta", {}).get("io.modelcontextprotocol.registry/publisher-provided", {}).get("github", {})
        out.append({
            "src": "github-reg", "name": sv["name"], "desc": sv.get("description", ""),
            "repo": gh.get("nameWithOwner") or repo_of((sv.get("repository") or {}).get("url")),
            "stars": gh.get("stargazerCount"), "license": gh.get("license"),
        })
    return out, None


def smithery(term, limit):
    d = get("https://registry.smithery.ai/servers?"
            + urllib.parse.urlencode({"q": term, "pageSize": limit}))
    if "_error" in d:
        return [], d["_error"]
    out = []
    for s in d.get("servers", []):
        out.append({
            "src": "smithery", "name": s["qualifiedName"], "desc": (s.get("description") or "")[:200],
            "repo": repo_of(s.get("homepage")), "uses": s.get("useCount"),
            "verified": s.get("verified"), "remote": s.get("remote"),
        })
    return out, None


_docker_names = None


def docker(term, limit):
    global _docker_names
    if _docker_names is None:
        try:
            r = subprocess.run(["gh", "api", "repos/docker/mcp-registry/contents/servers",
                                "--jq", ".[].name"], capture_output=True, text=True)
        except FileNotFoundError:  # no gh: fall back to the keyless API
            r = subprocess.CompletedProcess([], 127, "", "")
        if r.returncode != 0:
            d = get("https://api.github.com/repos/docker/mcp-registry/contents/servers")
            if isinstance(d, dict):
                return [], d.get("_error") or d.get("message")
            _docker_names = [x["name"] for x in d]
        else:
            _docker_names = r.stdout.split()
    hits = [n for n in _docker_names if term.lower() in n.lower()][:limit]
    out = []
    for n in hits:
        # server.yaml is flat enough to read without a YAML dependency.
        # type: server (an image, NOT always mcp/*) | remote (vendor-hosted URL)
        repo, kind, image, url = None, "?", None, None
        try:
            req = urllib.request.Request(
                f"https://raw.githubusercontent.com/docker/mcp-registry/main/servers/{n}/server.yaml", headers=UA)
            with urllib.request.urlopen(req, timeout=10) as resp:
                text = resp.read().decode("utf-8", "replace")
        except Exception:  # noqa: BLE001
            text = ""
        for line in text.splitlines():
            s = line.strip()
            if line.startswith("type:"):
                kind = s.split(":", 1)[1].strip()
            elif line.startswith("image:"):
                image = s.split(":", 1)[1].strip()
            elif s.startswith("project:") and repo is None:
                repo = repo_of(s.split("project:", 1)[1].strip())
            elif s.startswith("url:") and url is None:
                url = s.split("url:", 1)[1].strip()
        if kind == "remote":
            desc = f"docker catalog: remote {url or '?'} (vendor-hosted, no Docker-built image)"
        elif image and image.startswith("mcp/"):
            desc = f"docker catalog: image {image} (Docker-built)"
        else:
            desc = f"docker catalog: image {image or '?'} (third-party image, not Docker-built)"
        out.append({"src": "docker", "name": n, "desc": desc, "repo": repo})
    return out, None


def enrich(repo):
    try:
        r = subprocess.run(["gh", "api", f"repos/{repo}", "--jq",
                            "[.stargazers_count,.pushed_at,.archived,(.license.spdx_id//\"none\"),.open_issues_count,.fork]|@json"],
                           capture_output=True, text=True)
    except FileNotFoundError:  # no gh: rows keep registry-reported stars only
        return None
    if r.returncode != 0:
        return None
    s, pushed, arch, lic, issues, fork = json.loads(r.stdout)
    return {"stars": s, "pushed": pushed[:10], "archived": arch, "license": lic,
            "issues": issues, "fork": fork}


def main():
    args = sys.argv[1:]
    limit, do_gh, as_json = 15, True, False
    terms = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--limit":
            limit = int(args[i + 1]); i += 2; continue
        if a == "--no-github":
            do_gh = False
        elif a == "--json":
            as_json = True
        else:
            terms.append(a)
        i += 1
    if not terms:
        print(__doc__); sys.exit(1)

    merged, errors = {}, []
    for t in terms:
        for fn in (official, github_registry, smithery, docker):
            rows, err = fn(t, limit)
            if err:
                errors.append(f"{fn.__name__}({t}): {err}")
            for row in rows:
                key = (row.get("repo") or row["name"]).lower()
                m = merged.setdefault(key, {"names": set(), "srcs": set(), "desc": "", "repo": row.get("repo")})
                m["names"].add(row["name"]); m["srcs"].add(row["src"])
                m["desc"] = m["desc"] or row.get("desc", "")
                for k in ("packages", "remote", "uses", "verified", "version"):
                    if row.get(k) not in (None, [], ""):
                        m[k] = row[k]
                # publisher-provided, unverified: used only when gh enrichment is off/failed
                if row.get("stars") is not None:
                    m["reg_stars"] = row["stars"]
    if do_gh:
        for m in merged.values():
            if m["repo"]:
                e = enrich(m["repo"])
                if e:
                    m["gh"] = e
    # stars first: source count rewards whoever spammed every directory,
    # and Smithery useCount is self-reported/gameable.
    def stars(m):
        g = m.get("gh") or {}
        return g["stars"] if g.get("stars") is not None else (m.get("reg_stars") or 0)
    rows = sorted(merged.values(), key=lambda m: (-stars(m), -len(m["srcs"])))
    if as_json:
        for m in rows:
            m["names"] = sorted(m["names"]); m["srcs"] = sorted(m["srcs"])
        print(json.dumps({"results": rows, "errors": errors}, indent=1, default=str))
        return
    for m in rows:
        g = m.get("gh") or {}
        flags = []
        if g.get("archived"): flags.append("ARCHIVED")
        if g.get("fork"): flags.append("FORK")
        line = (f"[{len(m['srcs'])}src {','.join(sorted(m['srcs']))}] {m['repo'] or sorted(m['names'])[0]}"
                + (f"  ★{g['stars']} push:{g['pushed']} {g['license']} issues:{g['issues']}" if g
                   else (f"  ★{m['reg_stars']}(registry-reported, unverified)" if m.get("reg_stars") is not None else ""))
                + (f"  pkg:{'/'.join(m['packages'])}" if m.get("packages") else "")
                + (f"  remote:{m['remote']}" if m.get("remote") else "")
                + (f"  smithery_uses:{m['uses']}" if m.get("uses") is not None else "")
                + (" " + " ".join(flags) if flags else ""))
        print(line)
        print("    " + (m["desc"] or "").replace("\n", " ")[:160])
    if errors:
        print("\nERRORS (a source down is not 'no results'):")
        for e in errors:
            print("  " + e)


if __name__ == "__main__":
    main()
