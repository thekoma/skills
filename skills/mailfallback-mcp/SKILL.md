---
name: mailfallback-mcp
description: "Use when searching or reading backed-up mail, invoices, receipts or attachments in MailFallBack, or triggering a mailbox sync, over its MCP server."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [MailFallBack, MCP, Email, IMAP, Search, Attachments, Access-Tokens]
    related_skills: [mail-provision, agent-web-access-stack]
  endpoint: https://mfb.k8s.one/mcp/
  since: MailFallBack 2026.09.0
---

# MailFallBack over MCP

MailFallBack (MFB) backs up IMAP mailboxes to local Maildir and indexes them.
This skill covers its MCP surface: eight tools over streamable HTTP, one
static bearer token, two scopes that matter.

Read-only except `sync_now`. There is no tool that sends, edits or deletes
mail, and none that reaches another user's mailboxes.

## Connecting

Endpoint `https://<host>/mcp/` **with the trailing slash**. The app is mounted
at that path, so the bare `/mcp` answers a `307` redirect; not every client
follows a redirect on POST and some that do drop the body, so a client pointed
at the bare path can fail with nothing in the response to suggest the URL
rather than the token is at fault. Configure the slash form directly.

Auth is one header:

```
Authorization: Bearer mfb_<prefix>_<secret>
```

The scheme name is matched case-insensitively; a different scheme is rejected
rather than ignored.

**MFB is not an OAuth 2.1 resource server.** A client that insists on driving
discovery-and-grant before it will talk to a remote server will not connect.
A client that lets you set a static `Authorization` header works.

### Getting a token

Profile page → Access tokens → create with a name and scopes. Shown exactly
once, as `mfb_<prefix>_<secret>`. It cannot be recovered later, only revoked
and replaced.

| Scope | Grants |
|-------|--------|
| `mail:read` | The six read tools. |
| `sync:trigger` | `sync_now` **and** `sync_status`. |
| `imap` | IMAP/Roundcube login only. Reaches the MCP server but every tool call is refused. |

`mail:read` does not imply `imap`, and `imap` implies nothing here. Ask for
`mail:read` alone unless the task really needs to queue a sync.

## The eight tools

| Tool | Arguments | Scope |
|------|-----------|-------|
| `list_mailboxes` | *(none)* | `mail:read` |
| `search_mail` | `query`, `account_ids`, `range_start`, `range_end`, `include_deleted`, `snapshot_id`, `deep`, `page`, `page_size` | `mail:read` |
| `search_attachments` | `query`, `account_ids`, `exts`, `min_size`, `max_size`, `include_content`, `range_start`, `range_end`, `page`, `page_size` | `mail:read` |
| `get_message` | `account_id`, `message_id_hash` | `mail:read` |
| `download_attachment` | `account_id`, `message_id_hash`, `part_index` | `mail:read` |
| `imap_coords` | `account_id`, `message_ids` | `mail:read` |
| `sync_now` | `account_id` | `sync:trigger` |
| `sync_status` | `job_id` | `sync:trigger` |

Seven carry `read_only_hint: true`, so a client that surfaces the hint can
auto-approve them. `sync_now` is the only one that changes state.

`page_size` caps at 200 on both search tools.

## Search, then fetch

The whole surface is built around one pairing: a search hit carries
`account_id` + `message_id_hash`, and an attachment on that hit carries
`part_index`. Those are the only identifiers the fetch tools take, so there is
nothing to look up in between.

1. `search_mail` (or `search_attachments`) with the query.
2. `get_message(account_id, message_id_hash)` for headers and a body snippet,
   capped at 2048 characters.
3. `download_attachment(account_id, message_id_hash, part_index)` for the file,
   base64 in `content_base64`.

Start with `list_mailboxes` when you do not already know which mailbox to
search, or when the user's phrasing implies one ("my work mail"). Its
`indexed_messages` and `folders` describe **the search index right now**, not
a live provider-side count.

To keep working in an existing IMAP client instead of downloading over HTTP,
`imap_coords(account_id, message_ids)` turns Message-Ids into folder keys and
UIDs you can `SELECT`/`FETCH` directly. Note it takes real **Message-Ids**,
not the `message_id_hash` the other tools use.

## Responses that look like failures and are not

Treat these as data, not errors. Getting them wrong produces confidently wrong
answers ("you have no such email") from a call that never actually looked.

| Signal | Meaning | Do |
|--------|---------|-----|
| `partial: true` on `search_mail` with `deep: true` | The Dovecot body search timed out. Results so far, not everything checked. | Say the search was incomplete, or narrow it and retry. Never report "not found". |
| `imap_unavailable: true` on `imap_coords` | Dovecot was unreachable. **Every id in `missing` was never checked.** | Retry. Never conclude the mail is gone. |
| `already_queued: true` on `sync_now` | A sync was already pending or running; that job is returned. | Nothing further. Poll it with `sync_status`. |
| `content_search_available: false` on `search_attachments` | Content search is switched off, so `include_content` meant nothing. | Without this flag there is no way to tell "no matches" from "the feature is off". Say which. |
| `source` on `get_message` / `download_attachment` | Whether it came from the live Maildir or a restic snapshot. | Worth mentioning for an old message. |

## Errors

| Condition | Meaning |
|-----------|---------|
| 401 | Missing, malformed, expired or revoked token; or the owning user is disabled or mid-migration. Never falls back to a session. |
| 403 | Token is valid but lacks the scope. |
| Not found | A mailbox, message, attachment or job the caller cannot see. MFB does not confirm that something exists to someone not allowed to see it, so "no such job" covers both "never existed" and "not yours". Do not read it as proof of absence. |
| `message_id_hash` not valid hex | Malformed argument, not an authorization outcome. |
| attachment over 5 MB | `download_attachment` refuses rather than serving it. Use `imap_coords` and fetch over IMAP instead. |
| "attachment too large to extract" | The message was found but is too large to safely parse for that part. |

`sync_now` refuses outright, naming the reason, on a suspended or migrating
account, an account whose owner is migrating, or one carrying a
self-recovering pause (budget, throttle, transient). The web UI may warn and
override a pause; this tool never does, because an agent cannot weigh burning
the provider's daily quota on the owner's behalf. **Do not work around a
refusal** by retrying in a loop or by asking the user to lift the pause; report
it and move on. The pause clears itself.

## Limits worth knowing before you call

- `imap_coords` ignores ids past the first **200** entirely: not resolved, not
  reported missing. Chunk longer lists.
- `download_attachment` caps at **5 MB**.
- `get_message` body snippet caps at **2048 characters**. For the full body,
  go through IMAP via `imap_coords`.
- Both searches cap `page_size` at **200**; page rather than asking for more.

## Admin does not travel with the token

A token minted by an admin sees exactly that admin's own mailboxes. There is
no `include_all` on this surface. If the user asks you to search someone
else's mail through MFB, the answer is that this API cannot, by construction.

## Pitfalls

- **Pointing the client at `/mcp` without the slash.** The symptom looks like
  an auth failure. Check the URL first.
- **Reading `missing` from `imap_coords` without checking `imap_unavailable`.**
  This is the single most misleading response on the surface.
- **Reporting "not found" after a `partial: true` deep search.**
- **Asking for `sync:trigger` when the task only reads.** Scope creep on a
  credential that is also, potentially, an IMAP password.
- **Treating `indexed_messages` as the mailbox's real size.** It is what is
  indexed and searchable, which is the question `list_mailboxes` answers.
- **A cold call can fail at the transport.** `imap_coords` has been seen to
  return `SSE stream ended without a response` on a first call through the
  gateway and succeed on retry, with nothing in the application logs. One
  retry before concluding anything.

## Verification

Before reporting results:

- [ ] Did the search return `partial: true`? Say so.
- [ ] Did `imap_coords` return `imap_unavailable: true`? Retry, don't report missing ids.
- [ ] Is a "not found" actually proof of absence, or just invisible to this token?
- [ ] For an attachment you could not fetch: was it the 5 MB cap? Offer the IMAP route.
