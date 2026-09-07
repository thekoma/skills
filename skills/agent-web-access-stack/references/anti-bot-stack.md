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

Five containers: api, playwright-service, redis, rabbitmq, nuq-postgres, plus
an optional experimental FoundationDB queue backend (`NUQ_BACKEND=fdb`) that
replaces nuq-postgres — leave it off. Wires in via `FIRECRAWL_API_URL` plus
`web.extract_backend: firecrawl` / `web.search_backend: firecrawl`; set
`USE_DB_AUTHENTICATION=false` and no API key is needed.

Prefer the **keyless cloud free tier** (500 credits/month, no key, no infra)
until it demonstrably runs out. Self-hosting costs ~2G resident, which is the
wrong trade on a memory-pressured cluster; setting `FIRECRAWL_API_URL` later
moves extraction in-cluster without touching anything else.

**`extract_backend: firecrawl` with neither `FIRECRAWL_API_KEY` nor
`FIRECRAWL_API_URL` set is not "unconfigured" — it silently uses that keyless
public tier.** Detection is `_has_env("FIRECRAWL_API_KEY") or
_has_env("FIRECRAWL_API_URL")` in `web_tools.py`. Once the anonymous allowance
runs out every extraction fails with `403 Forbidden` from
`api.firecrawl.dev`, which reads like a hostile page rather than a missing
backend and sends you hunting for anti-bot workarounds. A named backend in
the config is not evidence that anything is deployed: grep for the credential
and the URL, and check whether the workload actually exists.

Run the API and its dependencies as sibling containers in **one pod** talking
over `127.0.0.1`: none of them then needs a Service, route or NetworkPolicy,
and only the API is reachable. Measured real footprint for the whole stack is
**~1.9G and ~50m CPU idle**. Three deployment traps come with that shape and
are documented in `k8s-gitops-self-modification`: an init container cannot
wait for a sibling, `HOME=/` is unwritable at a non-root uid, and the API
container needs **more than 2Gi** because the harness forks one Node process
per worker — cap `NUQ_WORKER_COUNT` and allow 3Gi, or it is OOMKilled before
binding its port and the symptom looks like a failing readiness probe.

**The queue can be entirely ephemeral.** `nuq.sql` ships in
`docker-entrypoint-initdb.d`, so an empty volume rebuilds the schema at boot;
a restart costs only in-flight scrape jobs and no domain data lives there. A
PVC here buys a backup obligation for work-in-flight.

**A shared Postgres cluster cannot host NuQ**, so do not offer it as the cheap
option without checking: `pg_cron` must be in `shared_preload_libraries`
(restarting every tenant) and `cron.database_name` is a cluster-wide setting a
single tenant cannot own — and stock CNPG images do not ship the extension at
all (`pg_available_extensions` lists only `pgcrypto`).

**There is no admin UI.** `apps/ui/ingestion-ui` is a React example template:
no published image, absent from the compose file, and its own README warns it
puts the API key in client-side code. The only real UI is the Bull queue admin,
off by default and gated behind `BULL_AUTH_KEY`. Exercise the service with
`POST /v2/scrape` instead.

**It composes with an existing SearXNG rather than duplicating it.** The
compose file exposes `SEARXNG_ENDPOINT` / `SEARXNG_ENGINES` /
`SEARXNG_CATEGORIES` as first-class env, so a self-hosted SearXNG already in
the cluster becomes Firecrawl's search source. Read the upstream compose for
these before designing any glue.

Traps:

- `NUQ_RABBITMQ_URL` is mandatory, not optional.
- Health probes: `/v2/health/liveness` **404s** on current builds. Use `/`,
  which returns the API banner only once the server is listening. Never take a
  health path from the API's shape — curl the candidates in the running
  container.
- Budget ~3G RAM actual against ~9.6G of declared limits, plus ~5 CPU. On a
  memory-pressured control-plane node this is the component that hurts;
  schedule it on the emptiest worker. Read live headroom
  (`kubectl top nodes` **and** each node's `Allocated resources`) rather than
  recalling which node was tight — a node at 41% memory can still be at 84%
  CPU requests, and the two pick different targets.
- The declared `cpus:`/`mem_limit:` in the upstream compose (8G api, 4G
  playwright) are sized for a dedicated host, not a shared cluster. Treat them
  as upper bounds to shrink, not values to port across.
- Upstream moved to the `firecrawl/*` GHCR namespace (`firecrawl/firecrawl`,
  `firecrawl/playwright-service`, `firecrawl/nuq-postgres`); the older
  `mendableai/*` paths return `DENIED` on a token request. Pin `firecrawl` to
  a concrete release tag — the supporting images publish only `latest` and
  per-arch tags.

### The prebuilt `nuq-postgres` image works — verify before building it yourself

Widely repeated write-ups claim the GHCR `nuq-postgres` image is broken (a
`pg_cron` `cron.database_name` disagreeing with the init script, dying with
"can only create extension in database postgres") and that it must be built
from source. Tested directly: the image starts clean, `pg_cron` loads, the
`nuq` schema and its queue tables are created, and the cron jobs run. The
settings the claim turns on agree:

```sql
SELECT extname, extversion FROM pg_extension;      -- plpgsql, pgcrypto, pg_cron
SELECT current_setting('cron.database_name');      -- postgres == POSTGRES_DB
\dt nuq.*                                          -- queue_scrape, group_crawl, ...
```

The general rule: **a "this prebuilt image is broken, build it yourself"
claim is a one-pod experiment, not a design constraint.** Run the image with
its documented env, read the logs and the setting the claim names, and only
then commit to a custom build pipeline — upstream fixes land without the
blog posts being updated, and a source build is the most expensive part of
any such plan.

When the container runtime is unavailable in your own pod (no Docker socket),
run the probe as a throwaway Kubernetes Pod pinned to the target node instead
of abandoning the test — `apply --dry-run=server` first, then delete it once
read, so nothing is left for ArgoCD to adopt.

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
- **Do not put an interactive search backend under scale-to-zero.** Measured
  end to end, a wake-up from zero takes over a minute: the first query returns
  502 through the gateway and only a retry ~20s later gets a 200, so every
  idle period costs the user a failed search. Warm requests answer in
  0.7–1.7s. Scale-to-zero is for workloads whose caller can wait or retry
  silently; a backend on the critical path of a user-facing tool is not one.
- **Removing an ElastiService takes two edits, not one.** Deleting the
  `ElastiService` frees the workload, but the app's ArgoCD
  `ignoreDifferences` almost certainly carries a
  `/spec/replicas` jsonPointer that existed only so selfHeal would stop
  fighting the operator. Leave it and nothing holds the replica count —
  remove it in the same commit so selfHeal actively pins replicas back to 1.
  Keep the readiness probe: it predates the autoscaler's needs and still stops
  the pod joining the EndpointSlice before the app binds during a rollout.
- **If you do run it under scale-to-zero keyed on ingress metrics, address it
  by its ingress hostname, not its ClusterIP Service.** When the ElastiService
  trigger is a Prometheus query over `envoy_cluster_upstream_rq_total` for its
  HTTPRoutes, traffic that bypasses the gateway neither wakes a scaled-to-zero
  pod nor counts as activity keeping a live one up — a ClusterIP client gets
  scaled out from under itself after the cooldown. Read the trigger
  (`kubectl get elastiservice <n> -o yaml`) before choosing an address.
- **Keep the hostname even after the autoscaler is gone.** Once scale-to-zero
  is removed the ClusterIP would work, but the ingress hostname is the same
  path external clients take, so a gateway or internal-CA certificate
  regression surfaces in the agent's own searches instead of hiding behind a
  shortcut. When you remove the autoscaler, rewrite the comment that justified
  the hostname rather than leaving a rationale that no longer holds.

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
