---
name: agent-web-access-stack
description: "Use when web_search, web_extract, or browser tools fail or hit bot walls."
version: 2.0.0
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [web, search, extract, browser, searxng, firecrawl, camofox, self-hosted, anti-bot, scraping, proxy]
    related_skills: [oss-alternative-evaluation, blocked-page-recovery, k8s-in-cluster-service-discovery, browser-exec-chrome-setup, k8s-gitops-self-modification]
---

# Agent web access stack

Use when `web_extract` refuses a URL, `web_search` is rate-limited or thin,
`browser_*` cannot reach a browser or gets 403s from bot walls, or when
evaluating an anti-bot / scraping architecture for this cluster.

The web layer is four independent slots with independent backends. Diagnose
and change them separately — conflating them is the usual reason a "fix"
doesn't fix anything, and a single "web is broken" report is almost always
wrong.

| Slot | Config key / env | Typical failure |
|---|---|---|
| Search | `web.search_backend` (or `web.backend`) | rate limit, thin results |
| Extract | `web.extract_backend` | *backend is search-only* — not a network problem |
| Browser | `browser.cloud_provider`, `CAMOFOX_URL`, `browser.cdp_url` | no browser / CDP refused; 403 on protected sites |
| Egress | proxy chain / node public IP | datacenter IP flagged, geo-wrong results |

A single `web.backend: ddgs` fills the search slot and leaves extract empty:
extraction then fails with a backend error, not a network error.

## Step 1 — read the error literally

`"<backend> is a search-only backend and cannot extract URL content"` is a
**configuration** message, not a fetch failure. Search-only backends (ddgs,
SearXNG, Brave, xAI) provide no extract path at all; retrying, changing the
URL, or invoking `blocked-page-recovery` will never help. Pair a search-only
backend with an extract-capable one instead.

Same discipline for the browser: `BU_CDP_URL ... unreachable` /
`Connection refused` means no browser is running for the harness to attach to.
That is setup state, not a blocked site.

**A 500 on the first browser call after an idle period is usually cold start.**
An anti-detection browser can need >60s to launch while the tab-create call
gives up at 30s, so the first request fails and the browser finishes starting
just after — the service log then shows a launch-succeeded line seconds after
the timeout. Read the browser service's own log for that line and simply
retry before restarting the deployment or concluding the target blocked you;
a restart resets the warm-up and reproduces the same failure once more.

Fall back to raw `curl` immediately when a fetch tool errors — it tells you
whether the site or the tool is at fault, and recovers most blogs and docs:

```bash
curl -sL -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36" "$URL" -o /tmp/page.html
```

Strip and print it in slices (`t[:12000]`, then the remainder); one dump of a
long article gets truncated and the tail — where technical posts keep the
gotchas — is silently lost.

**A truncated `web_extract` result is head+tail — the MIDDLE is what you are
missing.** When the footer reports truncation it also gives the path of the
complete text on disk and the `read_file` offset to resume at. Read that file
before drawing conclusions: on a long technical post the head is preamble and
the tail is the verdict, while the omitted middle is where the failure list,
the benchmark table and the caveats live. Treating head+tail as the whole
article reliably loses the only part worth extracting.

## Step 2 — read the actual current configuration

```bash
grep -A8 '^web:'     "${HERMES_HOME:-$HOME/.hermes}/config.yaml"
grep -A6 '^browser:' "${HERMES_HOME:-$HOME/.hermes}/config.yaml"
grep -oE '^[A-Z_]+=' "${HERMES_HOME:-$HOME/.hermes}/.env"   # names only, never dump values
```

**An explicit selection always beats a present credential.** Once
`web.backend` / `web.search_backend` / `web.extract_backend` (or
`browser.cloud_provider`) has ever been written, adding `SEARXNG_URL`,
`FIRECRAWL_API_KEY`, or `CAMOFOX_URL` to `.env` reroutes nothing — autodetect
from environment only runs on never-configured installs. The common real bug
is *both* halves at once: a credential pointing somewhere valid **and** a
config key still naming the old backend.

Per-capability keys beat the shared one:
`web.search_backend` / `web.extract_backend` > `web.backend` > autodetect.
Splitting them is the normal setup — free self-hosted search with a capable
extract provider is the intended pairing.

**The inverse bug is quieter: a backend named in config with no credential
behind it.** Selecting a provider does not check that it is reachable, so
`extract_backend: <provider>` with neither its API key nor its API URL set
leaves the slot pointing at nothing and Hermes silently degrades to a
*keyless rescue* against the vendor's public endpoint. That works at low
volume and then returns 403, so the same URL succeeds in the morning and
fails in the afternoon — which reads as a hostile site rather than an unset
credential. Two tells, both cheap:

- The error names the fallback, not the site: `Keyless <provider> extract
  failed`, `keyless rescue also failed`, or a bare `Set <PROVIDER>_API_KEY
  for reliable service`. Treat that string as *configuration*, never as a
  block, and do not escalate to `blocked-page-recovery`.
- Confirm against the activation predicate in the installed source rather
  than the config file. `tools/web_tools.py` gates each backend on an
  env check of the form `("<provider>", _has_env("<PROVIDER>_API_KEY") or
  _has_env("<PROVIDER>_API_URL"))`; if neither is present the named backend
  was never actually available. Also check whether the provider is deployed
  at all (`kubectl get pods -A | grep -i <provider>`) before assuming a
  self-hosted instance is behind the name.

So a slot has three states, not two: correctly wired, misrouted (credential
present, config names something else), and **named-but-uncredentialed**
(config right, nothing behind it). Diagnose which before changing anything.

**A leftover `browser.cdp_url` silently disables the browser selection.**
`is_camofox_mode()` returns False as soon as `browser.cdp_url` or
`BROWSER_CDP_URL` is non-empty, *before* it ever reads
`browser.cloud_provider`. A stale `cdp_url` from an earlier local-Chrome setup
keeps the selected provider switched off with no error anywhere — the config
reads exactly as intended and the backend is simply never used. Clear it
(`hermes config unset browser.cdp_url`) whenever selecting a cloud or
anti-detection browser. Read the selection helper in the installed source
rather than reasoning from the config file alone when a correct-looking
selection has no effect.

**`hermes config set browser.cloud_provider` warns that the key is not
recognised. Ignore it.** The key is authoritative —
`tools/tool_backend_helpers.py` defines
`_SELECTION_NAME_KEYS = {"browser": ("cloud_provider",), "web": ("backend",)}`.
Confirm a suspicious "unrecognised key" warning against that table before
hunting for a different key name.

## Step 3 — prove the endpoint works from where the agent runs

Test the exact URL in the config, from inside the agent's own process
environment. A service healthy in the cluster and a URL the agent can actually
reach are different claims.

```bash
curl -s -o /dev/null -w 'http=%{http_code} t=%{time_total}\n' "$URL/search?q=test&format=json"
```

For SearXNG specifically: `format=json` returns **403** unless `json` is listed
under `search.formats` in `settings.yml`, and SearXNG blocks requests by
User-Agent (curl/wget/python-requests) unless a proxy in front rewrites it.
Both are server-side config, so verify with a real JSON request rather than
assuming a 200 on `/` means the API works.

If the URL is an in-cluster ingress hostname, see
`k8s-in-cluster-service-discovery` — internal-CA TLS and scale-to-zero cold
starts both produce failures that look like the backend being down.

**Check egress before designing anything.** Run
`curl -s -4 --max-time 10 https://ipinfo.io/json`. If the exit IP already
resolves to a consumer ISP / residential ASN, every residential-proxy design
(SSH SOCKS5 tunnel, Privoxy bridge, Raspberry Pi hop) is dead weight — you are
already where those setups are trying to get to. Always `curl -4`; IPv6 egress
is blocked here.

## Step 4 — choose backends against real constraints

Order the fix by cost. A config edit that activates infrastructure you already
run beats deploying anything new; run the inventory in
`oss-alternative-evaluation` → "Step zero" first. Verify externally before
recommending: confirm an image tag really exists
(`ghcr.io/v2/<repo>/tags/list` with a pull token) rather than recalling it.

- **Search**: self-hosted SearXNG is free, multi-engine, and removes DDG rate
  limits. Confirm which engines are actually enabled — parse `engines` out of a
  JSON result rather than trusting the config file, since engines silently drop
  out when upstreams block the instance.
- **Extract**: needs a capable provider. Weigh a keyless/managed cloud tier
  against self-hosting; a self-hosted extract stack with a browser renderer,
  queue, cache and DB is a multi-gigabyte resident footprint — a real decision
  on a memory-constrained node, not a config change.
- **Browser / anti-bot**: an anti-detection browser (~0.5G) is the right tool
  for Datadome/Akamai/Cloudflare and beats a full extraction stack (~3G) when
  the goal is a handful of protected sites. But check what the integration
  *costs*: Camofox exposes no CDP endpoint, so selecting it forces Hermes back
  to the built-in browser tools and **removes `browser_exec`**. That is a
  capability trade, not a pure upgrade. Say so when proposing it.

Ship infra changes as a GitOps PR, never `kubectl apply`, and schedule
RAM-heavy components on a worker node, not on a control-plane node that is also
etcd and storage provider.

## Step 5 — prove each capability against a real target

A config that reads correctly and a service reporting healthy are both weak
evidence. A browser service returning `{"ok":true}` can fail every page load.
Exercise every slot you changed, end to end, and quote what came back:

- **search** — run a query whose answer must be fresh (today's news) so a stale
  cache cannot pass as success.
- **extract** — pull a real article and check the returned markdown carries a
  byline or timestamp. This is the slot most often left untested, because
  search working *feels* like the web layer working.
- **browser** — open an actual protected page and assert on content
  (`document.title`, body length, absence of captcha/"access denied" text). A
  returned `tabId` and the requested URL echoed back prove routing, not
  retrieval; a cookie-consent dialog or real markup is proof, an HTTP 200 is
  not.

Run these against the deployed workload, not the throwaway pod used while
debugging — confirm the fix landed in the real Deployment
(`kubectl get pod -o jsonpath=...` for the env var you added) before reporting
success.

## Isolating a variable when the output is randomised

Anti-detection stacks randomise their output by design, which breaks the
obvious A/B test. Fingerprint values (WebGL renderer, screen size) are drawn
fresh **per browser launch**, so two pods differing in one setting will show
different fingerprints whether or not that setting matters — the difference is
the randomiser, not your variable.

Before attributing any difference to the thing you changed:

- Establish the randomisation grain first. Two sessions on the *same* running
  instance isolate per-session variance; restarting the *same* instance with
  the *same* config isolates per-launch variance.
- Only fields stable across relaunches (`navigator.webdriver`, UA,
  `hardwareConcurrency`, plugin count) can carry signal in a cross-instance
  comparison. Treat the rest as noise unless a same-config relaunch says
  otherwise.
- Make the control genuinely comparable: to test whether disabling a security
  feature changes behaviour, the control must have that feature actually
  *working*, which may mean granting the privilege it needs. A control where
  the feature is silently broken measures nothing.

## Reviewing an architecture write-up for this user

The deliverable is not a summary. It is a diff between what the post builds and
what this environment already has:

- Name the components **already satisfied here** and therefore skippable, with
  the evidence (measured egress IP, existing config value).
- Name the components that address a problem this environment **actually has**,
  citing the live failure observed, not a hypothetical one.
- Give resource numbers per component and flag those that don't fit real
  cluster headroom.
- Close with an ordered cheapest-first shortlist and one concrete offer, not a
  menu.

This user distrusts homemade complexity and rejects proprietary or
licence-phoning binaries; prefer open-source, declaratively configured
components. Anti-bot strategy here rests on **browser-profile persistence**
(`userDataDir` on a PVC) plus a fetch cascade (curl → curl-cffi → real
browser), not on cookie lifetime or a paid scraping API.

When the ask is to mine an author's whole back catalogue rather than one post,
the same diff discipline applies per post, and two rules decide what survives:

- **Check each recommendation against live config before repeating it.** Grep
  the actual deployment for the thing the post fixes; a fix for a provider or
  gateway you do not route through is not advice, it is noise. Report "already
  satisfied, here is the evidence" as a finding in its own right.
- **Never propose swapping a component that is a chokepoint for all traffic**
  just because a post uses a different one. Equivalent-capability replacement
  of a working chokepoint is high blast radius for no measured gain; say so
  instead of listing it as an option.

When a post's own numbers are the valuable part, carry the author's *method*
rather than their conclusion: benchmark against your own prompts, distrust
vendor-recommended defaults, and note where the author deliberately overrode
their own benchmark and why — that reasoning transfers, the model names do not.

**Treat every factual claim in a write-up as a hypothesis with a one-command
test, especially "this component is broken".** Much of this genre is
AI-assisted and repeats defects that upstream has since fixed; a claim that
some prebuilt image must be built from source is the expensive kind, because
believing it commits you to a build pipeline you may not need. Run the thing
and read the specific setting the claim names — a disproved claim is a
finding worth reporting in its own right, and reporting it before writing any
manifest is what keeps the plan honest.

**Reading source settles capability; only third parties settle quality.**
Grepping a repo answers "can it do X" and cannot answer "is it any good" or
"how do its numbers hold up" — independent evaluators running competing tools
on a shared harness catch what code reading never will. Budget a search pass
for cross-vendor comparisons and reproductions before any adopt/reject
verdict, and say plainly which parts of the verdict rest on your own reading
versus on someone else's published measurement. See
`oss-alternative-evaluation` for the vendor-benchmark checks themselves.

## Pitfalls

- **Don't port a blog post's stack wholesale.** Write-ups bundle a working
  setup with the author's environment. The durable content is the pitfall list
  (JSON 403s, User-Agent blocks, broken prebuilt images); the deployment steps
  are provisional — and each named defect still needs the one-pod test above
  before it constrains the design.
- **Prefer a working extract backend over recovery heuristics.** Reaching for
  `curl` + regex, or the archive ladder, to read an ordinary public page is a
  sign the extract backend is unset, not that the page is hostile. Fix the
  configuration; save `blocked-page-recovery` for pages that genuinely block.
- **Changing config on a GitOps-managed pod goes through the repo.** A live
  edit is reverted by selfHeal — see `k8s-gitops-self-modification`. When the
  user explicitly asks for a live change, still use `hermes config set` /
  `unset` rather than editing `config.yaml` by hand; the binary usually lives
  outside `$PATH` in the container (`/opt/hermes/.venv/bin/hermes`, run with
  `HERMES_HOME` set), so look for it before concluding the CLI is unavailable.
  Mirror the same change into the GitOps seed, or the next volume rebuild
  silently reverts it.
- **A config-seed ConfigMap only applies to an empty volume.** Init containers
  that seed `config.yaml` skip the copy when the file exists, so merging the
  GitOps change leaves a long-lived pod running the old settings. After a
  merge, verify the live file, not the repo.
- **`web_tools` re-reads `config.yaml` per call, so backend changes need no
  restart.** Verify by calling the tool rather than scheduling a rollout;
  credentials resolved through `get_secret` do come from the process
  environment and only change on restart, so a *new* env var still requires
  one. Check which of the two a change actually touches before restarting a
  gateway that is serving the user.

## Depth

`references/anti-bot-stack.md` — component notes on Camofox, self-hosted
Firecrawl + SearXNG, and the Privoxy/SOCKS5 chain, with the configuration traps
that break each one.
