---
name: multimodal-itinerary-search
description: "Use to find mixed air+rail routes in Europe; trvl MCP."
version: 1.0.0
author: Andrea Cervesato (thekoma), Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [travel, flights, rail, trains, multimodal, trvl, transitous, mcp, europe]
    related_skills: [business-travel-planning, mcp-server-discovery]
---

# Multimodal itinerary search (air + rail, Europe)

## When to Use

Use this when someone needs to get from A to B in Europe and the obvious option is
broken or poor: the direct train is suspended, the flight lands far out of town,
or no single carrier serves the pair. The answer is often "fly to a hub, then
take a train", and single-vendor tools never propose it. A carrier's site sells
its own network and an airline aggregator ignores trains.

This skill covers the search. Choosing between options for a payer, mails and
booking all belong in `business-travel-planning`.

## Step 0: check the calendar

Travellers often book before they ask, and one order can hold both legs.
Search every mailbox, not only the first one that answers. Look for flight or train confirmations
on the travel dates (calendar events created from mail, or booking mails)
before you search anything. If a booking exists, check it instead: confirm each
leg still runs, the connection margin, and the real arrival time. Arrival times
in calendar events auto-created from mail are often wrong. Re-derive them from
the operator's timetable.

## Tools

### trvl (MCP, primary)

`github.com/MikkoParkkola/trvl` is a single Go binary that serves MCP over stdio,
or over HTTP with `--http` plus a bearer token.

- **Flights:** Google Flights and Kiwi, merged.
- **Ground:** Trenitalia, Italo, DB, OBB, Renfe, FlixBus, RegioJet, Eurostar,
  SNCF, Trainline and Transitous (pan-European GTFS).
- **MCP surface:** a single `travel` router tool. Pass
  `{"intent": "<capability>", "params": {...}}` with a capability name
  (`search_flights`, `search_ground`, `search_dates`, `find_trip_window`,
  `plan_multimodal`...) or `{"query": "natural language"}`.
- **`params` is untyped in the tool schema, and field names differ per
  capability.** Guessing them burns retries and trips loop guards. Use exactly:

  ```json
  {"intent": "search_flights", "params": {"origin": "LIN", "destination": "CDG", "departure_date": "2026-10-05", "max_stops": "nonstop"}}
  {"intent": "search_ground",  "params": {"from": "Torino", "to": "Lyon", "date": "2026-10-23"}}
  ```

  Flights take **IATA codes** (`TRN`, not `Torino`) and `departure_date`.
  Ground takes **city or station names** and `date`. Optional on both:
  `return_date`, `currency`, `max_price`. Ground also takes `provider`
  (`"trenitalia,db,transitous"`) and `type` (`train`/`bus`/`ferry`). An empty
  flight result for a pair with no nonstop service is an answer, not an error:
  drop `max_stops` or move to the hub procedure.
- **Read-only deployments:** start it with a **read token**
  (`TRVL_MCP_READ_TOKEN`). trvl then refuses every read-write capability
  (`watch_price`, `update_preferences`, trip and profile mutations) with
  `-32001` before it runs. That is the only real boundary, because a gateway
  allowlist on tool names cannot narrow a single router tool.
- **Headless hardening:** set `TRVL_NO_TELEMETRY=1`,
  `TRVL_DISABLE_UPDATE_CHECK=1`, `TRVL_NO_BROWSER_COOKIES=1` and
  `TRVL_NO_TIER2_CDP=1`. By default it reads the host browser's cookies and can
  start headless Chrome.
- **License:** PolyForm Noncommercial. Personal use is fine; commercial use
  needs a licence.

The CLI mirrors the MCP and is the fastest way to test from a shell:

```bash
trvl flights MXP,LIN CDG,ORY 2026-10-05 --stops nonstop
trvl ground Paris Lyon 2026-10-05 --provider db,transitous
```

Pass `HOME=<dir>` per command when sandboxing it. Never `export HOME`, which
breaks `gh` and `git` later in the same shell.

### Transitous (keyless REST, rail timetables)

Transitous (`api.transitous.org`, MOTIS 2) carries open GTFS for most European
operators, SNCF included. It returns service numbers and times, but no fares.
Call it directly when trvl's ground search comes back without the leg you need:

```bash
curl -s "https://api.transitous.org/api/v1/geocode?text=Lyon%20Part-Dieu"   # -> id
curl -s "https://api.transitous.org/api/v5/plan?fromPlace=<id>&toPlace=<id>&time=2026-10-05T15:30:00Z&numItineraries=5"
```

Times in the response are **UTC**. Convert before quoting them.
The geocode `id` ends with a trailing `:`. Pass it to `plan` exactly as
returned: if you strip or re-join the colon, you get a 404 `Could not find
timetable location`.
`legs[].tripShortName` holds the train number (TGV 12536 and so on). Send a
`User-Agent`.

## Procedure

1. **Try the direct ground leg first.** Run `search_ground` (or `trvl ground`)
   on the city pair. Read the shape of what comes back: when the usual direct
   high-speed train shows up as multi-change itineraries routed through a third
   country, the line is closed for works. No API says so explicitly.
2. **Pick candidate hubs.** These are airports with a long-distance rail station
   on site or one short hop away. Paris CDG has a TGV station inside terminal 2
   with direct trains to Lyon, Marseille, Lille and Brussels. Frankfurt FRA,
   Amsterdam AMS, Zurich ZRH and Brussels BRU are in the same class. Prefer an
   airport-station hub over a city-centre one: it saves a cross-town transfer.
3. **Search the air leg to each hub nonstop.**
   `search_flights` with `max_stops: nonstop`. Include every origin airport
   (Milan = MXP, LIN, BGY). A default sort returns virtual-interlining
   detours through distant hubs.
4. **Search the rail leg from the hub** at times after the landing. Allow at
   least 90 minutes for a terminal-to-train connection with luggage, and more
   for non-Schengen arrivals.
5. **Join the legs and rank them door to door.** Compare arrival time at the
   real destination (city centre, not the airport) and total cost. Label every
   leg with its carrier code and service number (`AZ 312`, `TGV 12536`).
6. **Label what is verified.** Flight fares from Google and Kiwi are live
   snapshots. A rail leg from Transitous has times but no fare. Say so, and
   point to the operator site for the price.

## Known blockers from datacenter or cluster IPs (measured 2026-10)

| Provider | From a non-residential IP | Effect |
|---|---|---|
| SNCF Connect, Trainline | 403 (bot wall) | no French rail fares; use Transitous for times |
| Rome2Rio | 403 (Cloudflare) | `plan_multimodal` / `trvl multimodal` cannot discover combos: compose them yourself (procedure above) |
| Wizz Air | 503 (CloudFront edge block) | Wizz missing from flight results |
| Google Flights, Kiwi, Trenitalia, DB, FlixBus, Transitous | OK | core coverage intact |

**Italo fails differently.** On some resolvers its login host
(`biglietti.italotreno.com`) fails to resolve with `server misbehaving`.
That is a DNS problem on your side, not a provider block. Test from the host
that will run trvl before you count Italo as covered.

## Pitfalls

- **Missing train details shared as screenshots.** Colleagues share a ticket
  as an image, so the train number never appears in message text. Open the
  attachments.
- **Retrying a tool that times out at a fixed round number** (10.0s, 30.0s).
  That is a proxy deadline, not a slow provider. Switch source after the
  third identical failure.
- **Treating `plan_multimodal` as the answer.** It depends on Rome2Rio, which
  is blocked headless. An empty or blocked result there does not mean "no
  combo exists".
- **Calling a route a "direct train" from a published timetable.** Timetables
  describe the normal year. Engineering closures remove trains that every
  table still lists, so query the operator or Transitous for the actual date.
- **Quoting Transitous times as local time.** They are UTC.
- **Trusting the arrival time in a calendar event auto-created from mail.**
  These often carry a placeholder end time.
- **Comparing flight time against train time.** Compare door to door: add the
  airport transfer at both ends.
- **Reading an aggregator's "N trains found" as N direct services.** The count
  includes connections.

## Verification

- [ ] Calendar and mail checked for existing bookings first.
- [ ] The direct ground option was searched, and its itinerary shape read.
- [ ] Air legs were searched nonstop, across every origin airport.
- [ ] The rail leg from the hub was confirmed for the actual date, with the
      service number.
- [ ] Connection margin stated, and arrival given at the real destination.
- [ ] Each figure is labelled live fare, timetable only, or indicative.
