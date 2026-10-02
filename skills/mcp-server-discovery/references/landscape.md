# MCP discovery landscape: probe log (verified 2026-10-02)

Re-run these probes when a source starts misbehaving. Directory APIs churn fast:
PulseMCP sunset its public API within a year.

## Official MCP Registry
- `GET https://registry.modelcontextprotocol.io/v0.1/servers?search=<s>&version=latest&limit=<n>&cursor=<c>`
- OpenAPI: `https://registry.modelcontextprotocol.io/openapi.yaml`. API frozen at v0.1 since 2025-10-24. Registry is still labelled "preview".
- Response: `servers[].server` = server.json (`name`, `description`, `version`,
  `repository.url`, `packages[]{registryType npm|pypi|oci|mcpb|nuget, identifier, transport.type, runtimeArguments, environmentVariables[isSecret]}`,
  `remotes[]{type streamable-http|sse, url, headers}`), `_meta["io.modelcontextprotocol.registry/official"]{status, publishedAt, isLatest}`.
- `search` = case-insensitive substring on `name` only. `kubernetes` -> 2 hits, `k8s` -> 11 different ones; `aks` matched `akshare`, `leaks`. No description search, so multi-word queries return nothing.
- Namespaces: `io.github.<user>/*` is proven by GitHub OAuth, reverse-DNS (`com.vendor/*`) by DNS/HTTP challenge. This proves the publisher's identity, not the code's safety. The registry runs no security scan (its docs say so).
- Designed for aggregators to ETL hourly, not for end-user search.

## GitHub MCP Registry
- `GET https://api.mcp.github.com/v0.1/servers?search=<s>&limit=<n>`. Same schema, plus `_meta["io.modelcontextprotocol.registry/publisher-provided"].github{nameWithOwner, stargazerCount, license, pushedAt, readme}`.
- `x-ratelimit-limit: 10` per window, anonymous. Small curated set. Web UI: github.com/mcp.

## Smithery
- `GET https://registry.smithery.ai/servers?q=<s>&pageSize=<n>&page=<p>`: keyless, full-text. Fields: `qualifiedName`, `verified`, `useCount`, `remote`, `isDeployed`, `homepage`, `createdAt`.
- `GET https://registry.smithery.ai/servers/<qualifiedName>`: `connections[]`, `security`, **`tools[]` with inputSchema**, `resources`, `prompts`. Cheapest way to read a tool surface without running anything (k8scortex: 75 tools).
- Most entries are Smithery-hosted (`https://<slug>--<ns>.run.tools`). Ranking mixes in off-topic results: for `kubernetes` it returned Korean crypto and payment servers.

## Docker MCP Catalog
- `gh api repos/docker/mcp-registry/contents/servers` -> ~328 dirs. `servers/<n>/server.yaml`: `image: mcp/<n>`, `source.project`, `source.commit` (pinned), `config.parameters`, `run.volumes`.
- Docker builds, signs and ships an SBOM for `mcp/*` images. Strongest provenance among community servers.

## Glama
- Web: `glama.ai/mcp/servers` (~95k), per-server page with license/quality/maintenance grades, a tools tab and related servers. `web_extract` reads it fine.
- API `https://glama.ai/api/mcp/v1/servers|connectors`: **401 without key**. The API Data License requires visible attribution plus a per-record backlink, waivable only under a commercial licence. Do not wire it into automation.

## PulseMCP
- `api.pulsemcp.com/v0beta/*`: sunset with a staged failure rate, 100% since 2026-09 (`API_SUNSET`).
- `api.pulsemcp.com/v0.1/servers`: needs `X-API-Key` and `X-Tenant-ID` (B2B partners). Implements the generic registry spec plus `com.pulsemcp/*` enrichments (`isOfficial`, `visitorsEstimateLastFourWeeks`, premium `tools`, `authOptions`). Its own MCP server (`pulsemcp/mcp-servers/productionized/pulse-subregistry`) is unusable without a tenant.

## Hermes built-in
- `hermes mcp catalog` / `hermes mcp install <name>`: 64 Nous-approved entries, mostly vendor-hosted remotes (atlassian, cloudflare, datadog, figma, gitlab...). context7 and deepwiki are already enabled on our install.

## Security tooling
- `cisco-ai-defense/mcp-scanner` (Apache-2.0, ~1.1k★): YARA, LLM (litellm, any model), Cisco API (optional), behavioural source scan, pip-audit, VirusTotal (opt-in). `static` subcommand works offline on JSON. Verified in a musl container via uvx: 75 real tools SAFE, a planted `<IMPORTANT>` poisoning description HIGH (2 findings).
- `snyk/agent-scan` (ex invariantlabs mcp-scan, ~3.1k★): needs `SNYK_TOKEN` and sends tool descriptions and configs to the Snyk API. Asks consent before starting stdio servers. Hash-based tool pinning dropped in 2026.
- OWASP MCP Top 10 (MCP01 token mismanagement, MCP02 scope creep, ...) plus the OWASP MCP Security Cheat Sheet.
- Prevalence: about 5.5% of ~1.9k public servers showed tool poisoning (Hasan et al. 2025); AgentSeal reports similar numbers.

## Not worth a source slot
mcp.so, mcpservers.org (awesome list mirror, ~9.8k), mcpm.sh (CLI with its own small registry),
safemcp.info, Lulu MCPs (aggregator of official+Glama+PulseMCP+Smithery), "best N MCP servers 2026"
listicles. They add no signal the four primary sources lack.
