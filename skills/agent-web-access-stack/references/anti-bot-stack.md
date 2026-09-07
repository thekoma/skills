# Anti-bot web access components

Component notes for hardening agent web access. Adopt in the order below
(cheapest first); most environments never need the whole chain.

## Camofox — anti-detection browser (first choice)

Firefox fork (Camoufox) with C++-level fingerprint randomisation:
`navigator.webdriver`, WebGL renderer, canvas, audio context, plugin list.
Headless Chromium leaks all of these, which is why Playwright/Puppeteer alone
loses to Datadome, Akamai and PerimeterX regardless of how the page is driven.

- Image: `ghcr.io/jo-inc/camofox-browser` (query
  `ghcr.io/v2/jo-inc/camofox-browser/tags/list` with a pull token before
  pinning). Pin an explicit tag, never `latest`: the image bundles a
  fingerprint database, so an unattended tag move changes anti-detection
  behaviour underneath you.
- Hermes wiring is `CAMOFOX_URL=http://<host>:9377` **plus** an explicit
  `browser.cloud_provider: camofox` selection. The env var alone does not
  reroute a config that already carries a browser selection — autodetection
  only runs on a never-configured setup.
- **Camofox exposes no CDP endpoint**, so the Browser Use harness cannot attach
  and Hermes falls back to the built-in browser tools. You lose `browser_exec`
  (model-written Python in the page). Decide this trade-off deliberately; it is
  a downgrade in ergonomics bought for passage through commercial WAFs.
- Configured entirely by ENV, not a config file. Health: `GET /health`.

### Kubernetes deployment requirements (all four are load-bearing)

A default Deployment comes up `Running`, passes its probe, and then fails every
single page load. Four settings decide whether it actually works:

1. **`/dev/shm` must be a memory-backed emptyDir**, not the 64MB Kubernetes
   default. Firefox puts shared-memory segments there.
2. **`MOZ_DISABLE_CONTENT_SANDBOX=1`** whenever the pod runs
   `allowPrivilegeEscalation: false` + `capabilities: drop: [ALL]`. Firefox's
   content sandbox forks children through an unprivileged user namespace;
   `NoNewPrivs=1` and `CapBnd=0` make that clone fail. See the debugging
   section below — this is the failure that looks like everything else.
3. **`$HOME` needs its own PVC.** The image does *not* ship the browser:
   `camoufox-js` downloads a ~663MB bundle into `/root/.cache` on first launch
   (~1.3G resident once unpacked). On an emptyDir that consumes node ephemeral
   disk and is re-downloaded on every restart.
4. **`MAX_OLD_SPACE_SIZE`** defaults to 128MB — tuned for a $5 VPS and too
   small for large accessibility snapshots. 512 is a reasonable floor.

Resource reality: ~300Mi RSS idle with the browser lazily stopped
(`BROWSER_IDLE_TIMEOUT_MS`, default 5min), ~700Mi with a live session, plus
~1.3G of browser bundle on disk. Budget 2Gi limit.

Keep it ClusterIP with no HTTPRoute and no `CAMOFOX_ACCESS_KEY` only if the
cluster boundary is genuinely the auth boundary — it is a browser that will
fetch any URL handed to it from your egress IP, i.e. an SSRF pivot if exposed.
Disable vendor crash telemetry (`CAMOFOX_CRASH_REPORT_ENABLED=false`); it is on
by default and posts to a third-party endpoint.

Set `browser.camofox.managed_persistence: true` and point
`CAMOFOX_PROFILE_DIR` at the PVC: a stable profile is what makes a residential
IP look like a returning human rather than a first-time visitor. Also set
`browser.auto_local_for_private_urls: false` when Camofox runs in-cluster —
otherwise LAN/loopback URLs get diverted to a local Chromium sidecar that does
not exist in the image.

### Debugging "tab create failed" / HTTP 500 on every URL

`GET /health` returns `{"ok":true}` while every `POST /tabs` returns 500. The
health check only proves the Node server and the parent `camoufox-bin` process
are alive; it says nothing about whether a page can be created. Never accept
`/health` as evidence the browser works — create a tab against `example.com`.

Diagnostic order, cheapest first:

- **Reproduce on `example.com` first.** If a plain, unprotected page also
  returns 500, the problem is the container, not anti-bot. This one check
  separates "Camofox is broken" from "the site blocked us" and saves a long
  detour into fingerprinting.
- `ps aux` inside the pod. `[Sandbox Forked] <defunct>` zombies mean the
  content sandbox cannot fork — apply `MOZ_DISABLE_CONTENT_SANDBOX=1`.
  Confirm the mechanism directly with
  `unshare --user --map-root-user echo ok`; `write failed /proc/self/uid_map:
  Operation not permitted` is the same root cause stated plainly.
- `df -h /dev/shm`. 64M means fix (1) above.
- The symptom for both is identical — a 10s `newPageTimeoutMs` surfacing as
  `new page retry timed out after 10000ms` — so fixing one and re-testing is
  the only way to tell them apart.

### The content sandbox does not affect fingerprint spoofing

Verified empirically, because it is a reasonable thing to worry about:
Camoufox intercepts at the C++ implementation level, compiled into the binary
below the JS layer. The content sandbox is a **process-isolation** boundary
(what a content process may ask the kernel for), not part of the spoofing path.
With the sandbox disabled, `navigator.webdriver`, UA, `hardwareConcurrency` and
plugin count are injected identically to a sandboxed run.

What you actually give up: a Gecko RCE runs in the browser process instead of a
confined content process. Inside a container with zero capabilities, no
privilege escalation and its own namespaces, that is the better half of the
trade — the alternative is granting `SYS_ADMIN` to restore the inner boundary
by weakening the outer one.

### Fingerprint varies per browser LAUNCH, not per session

BrowserForge picks a fresh profile each time the browser process starts. Two
sessions on the same running pod get an identical fingerprint; restarting the
pod changes screen size and WebGL renderer entirely. This is a trap when
comparing configurations — see "Isolating a variable" in the parent skill.

The generated profile pool is not uniformly good: `llvmpipe` (Mesa's software
rasteriser) shows up as a WebGL renderer on some launches and is nearly as
strong a headless tell as SwiftShader. If a portal starts blocking
intermittently with no config change, suspect a weak draw from the pool before
suspecting the stack.

## Self-hosted Firecrawl — extraction and search (only if Camofox is not enough)

Five containers: api, playwright-service, redis, rabbitmq, nuq-postgres. Wires
in via `FIRECRAWL_API_URL` plus `web.extract_backend: firecrawl` /
`web.search_backend: firecrawl`; set `USE_DB_AUTHENTICATION=false` and no API
key is needed.

Prefer the **keyless cloud free tier** (500 credits/month, no key, no infra)
until it demonstrably runs out. Self-hosting costs ~3G resident, which is the
wrong trade on a memory-pressured cluster; setting `FIRECRAWL_API_URL` later
moves extraction in-cluster without touching anything else.

Traps:

- **Do not use the prebuilt `nuq-postgres` GHCR image** — its `pg_cron`
  `cron.database_name` disagrees with the init script's database and it dies at
  startup with "can only create extension in database postgres". Build it
  locally from `src/apps/nuq-postgres` in the Firecrawl repo, cloned into the
  compose file's `src/` subdirectory so the relative `build:` path resolves.
- `NUQ_RABBITMQ_URL` is mandatory, not optional.
- Budget ~3G RAM actual against ~9.6G of declared limits, plus ~5 CPU. On a
  memory-pressured control-plane node this is the component that hurts;
  schedule it on a worker or skip it.
- Upstream moved to the `firecrawl/*` GHCR namespace (`firecrawl/firecrawl`,
  `firecrawl/playwright-service`, `firecrawl/nuq-postgres`); the older
  `mendableai/*` paths return `DENIED` on a token request.

## SearXNG — multi-engine search

Can run as Firecrawl's search backend, but Hermes also speaks to it directly:
`SEARXNG_URL` plus `web.search_backend: searxng`. Search only — it has no
extract API, so pair it with a separate `web.extract_backend`.

Traps:

- The JSON API returns **403 until `json` is added to `search.formats`** — it
  is HTML-only by default.
- SearXNG blocks clients by User-Agent (`curl`, `wget`, `python-requests`) even
  with the limiter off. Put nginx in front and rewrite the header to a desktop
  browser UA.
- With the limiter on, list container/LAN CIDRs in `limiter.toml` under
  `[botdetection.ip_limit] trusted_proxies`, or internal traffic is treated as
  spoofed.
- **Under KubeElasti (or any scale-to-zero keyed on ingress metrics), address it
  by its ingress hostname, not its ClusterIP Service.** If the ElastiService
  trigger is a Prometheus query over `envoy_cluster_upstream_rq_total` for its
  HTTPRoutes, traffic that bypasses the gateway neither wakes a scaled-to-zero
  pod nor counts as activity keeping a live one up — a ClusterIP client gets
  scaled out from under itself after the cooldown. Read the trigger
  (`kubectl get elastiservice <n> -o yaml`) before choosing an address; the
  cheaper-looking hop is the wrong one here. Cold start is ~10s, warm ~1s.

## Residential egress chain — usually unnecessary

Privoxy (`:8118`) bridges HTTP→SOCKS5 to an SSH `-D 1080` tunnel terminating on
a machine with a consumer ISP connection. Only build this when
`curl -s -4 https://ipinfo.io/json` shows a datacenter ASN; a homelab already on
a residential line gets the benefit for free.

If you do build it:

- Privoxy defaults to `listen-address 127.0.0.1:8118`; containers on bridge
  networks cannot reach the host loopback and every request dies with
  `ECONNREFUSED`. Bind `0.0.0.0:8118`.
- Point the tunnel at a stable overlay address (Tailscale) rather than a dynamic
  public IP, or it breaks on every ISP lease change.
- Design for **no silent fallback**: if the tunnel dies, requests should fail
  rather than leak from the datacenter IP and burn the profile's credibility.
- Expect geo-skewed search results matching the exit IP's country.

## Composition note

Scrapling (BSD-3, open source) implements the curl → curl-cffi → browser
cascade and speaks remote CDP, so it composes with Camofox as the warm browser
rather than competing with it. Preferred over closed "cloak browser" products,
which ship proprietary binaries and licence phone-home.
