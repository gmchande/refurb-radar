# PRD: Fast Detection Rebuild

Created: 2026-06-10
Status: archived
Tracker: none configured; this file is historical and no longer the active PRD.
Supersedes the detection core of `docs/archive/prd-refurb-radar-redesign.md`. The universe, declarative targets, alert receipts, and durability work from that PRD stand; this PRD replaces how the watcher detects listings and confirms buyability.

## Problem Statement

I need to be the first to know when a refurbished Mac I want hits Apple's inventory, and I am not. A free email service beat my custom watcher to overnight and morning restocks, including the 64GB configuration I wanted most. The watcher was alive and checking, and it still lost the race.

It lost for two reasons, both now proven against Apple's live responses. First, it learns about new listings from the refurb grid, which it only polls every 30 minutes; a machine that appears and sells out inside that window is invisible to me. Second, it confirms buyability by fetching each product page's HTML and reading a `schema.org` stock marker that Apple serves from a cache and that flaps between in-stock and out-of-stock for an hour while the machine is not actually buyable. So the watcher is both slow to see new listings and noisy about whether they can be bought, which produced both missed alerts and, after a bad patch, a burst of false ones.

I also do not get told about a machine more than once. If I miss the single SMS, the watcher never nudges me again even while the machine sits buyable.

## Solution

Stop fetching heavy product pages and stop reading the flapping cache marker. Apple's own storefront is backed by two cheap, authoritative surfaces that I verified directly:

- The refurb grid bootstrap lists every refurbished Mac currently in inventory. A part number appearing there is the listing event, the same signal the email service reacts to. One fetch covers the whole catalogue and doubles as discovery of configurations I did not know existed.
- A buyability endpoint returns a true or false "is buyable" flag for every watched part number in a single sub-second call, served fresh from origin on every request rather than from a cache. This is the real checkout signal, the one the store itself uses, and it does not flap the way the page marker does.

The watcher polls both every ten seconds or so. A new wanted part number in the grid pages me immediately that it is listed. The buyability flag flipping to true pages me with a phone call that it is buyable, after one confirming re-check so a single bad sample cannot ring me for nothing. While it stays buyable I get a reminder every few minutes until it sells out. The result is faster detection, an authoritative buyable signal that ends the false-positive problem, and a steady nudge so a fleeting restock does not slip past me because I looked away.

## User Stories

1. As a refurb buyer, I want to be told a wanted machine is listed within seconds of Apple publishing it, so that I learn about restocks as fast as or faster than any third-party service.
2. As a refurb buyer, I want listing detection to read Apple's inventory grid rather than wait on a slow discovery cycle, so that a machine that appears and sells out quickly is never missed.
3. As a refurb buyer, I want a first message the moment a wanted part number is listed, even before buyability is confirmed, so that I can start paying attention immediately.
4. As a refurb buyer, I want buyability confirmed from Apple's authoritative buyable flag rather than a cached page marker, so that I am not paged on a machine that cannot actually be bought.
5. As a refurb buyer, I want a phone call the moment a wanted machine is confirmed buyable, so that I am interrupted in time to buy it before it sells out.
6. As a refurb buyer, I want the call to fire only after one confirming re-check, so that a single bad reading never rings my phone for a machine that is not really buyable.
7. As a refurb buyer, I want a reminder message every few minutes while a machine stays buyable, so that missing the first alert does not cost me the machine.
8. As a refurb buyer, I want reminders to stop the instant a machine sells out, so that I am never chasing a listing that is already gone.
9. As a refurb buyer, I want the reminder cadence to nudge me at any hour, so that an overnight restock still reaches me.
10. As a refurb buyer, I want a phone call for every buyable wanted machine, not only the highest configurations, so that I do not miss a match because it was deemed lower priority.
11. As a refurb buyer, I want the alert to carry the part number, title, and a direct link, so that I can open the page and buy in seconds.
12. As a refurb buyer, I want the same machine alerted again when it sells out and later restocks, so that recurring inventory is treated as a fresh chance.
13. As a refurb buyer, I want one listing alert per listing and one buyable alert per buyable window, separate from the reminders, so that the messages mean distinct things.
14. As the operator, I want the watcher to hold a session against Apple's store and refresh it when it expires or is rejected, so that the cheap endpoints keep working without manual intervention.
15. As the operator, I want one buyability call to cover every watched part number, so that confirming the whole watchlist costs a single fast request rather than dozens.
16. As the operator, I want the grid poll to also grow the durable universe, so that listing detection and discovery are the same cheap step and new configurations are picked up automatically.
17. As the operator, I want the watcher to keep checking buyability even if a grid poll fails, and keep detecting listings even if a buyability call fails, so that one surface breaking does not blind the other.
18. As the operator, I want every listing event, buyability flip, confirming re-check, alert, and reminder recorded with timestamps, so that I can reconstruct exactly what happened and when.
19. As the operator, I want Apple's per-response timing and cache markers logged, so that I can measure how fresh and how fast our reads actually are.
20. As the operator, I want each machine's "first detected at" timestamp retained, so that I can line our detection up against a third-party email to the second and prove who was faster.
21. As the operator, I want a loud alarm when a poll surface starts failing or returns blocked responses across the board, so that a bot block looks like an outage rather than an empty store.
22. As the operator, I want polite, browser-like, jittered polling that backs off on rejection, so that the watcher stays under Apple's anti-bot thresholds.
23. As the operator, I want the heavy product-page fetch kept only as a fallback verifier, so that the system still has a second opinion if the cheap signal is ever ambiguous.
24. As the operator, I want the alert ladder driven by the authoritative flag with at most a thin single-sample guard, so that yesterday's flap-suppression cooldown can be retired and a genuine second restock within the hour alerts immediately.
25. As the operator, I want state, events, and the session to stay in small local files, so that the system remains inspectable without a database.
26. As a future user of other products, I want the polled surfaces, country store, and watchlist driven by configuration, so that watching another product line or another country's store is setup rather than a rewrite.
27. As an agent working on this codebase, I want the new endpoints reachable through the existing fake-fetcher and injected-clock seams, so that the full detect-confirm-remind ladder is testable without touching apple.com.

## Implementation Decisions

- **Two-surface fast loop replaces the per-SKU page fan-out.** Each pass, on a jittered roughly ten-second cadence, makes two fetches: the refurb grid bootstrap (one request, full catalogue) and the buyability endpoint (one request covering all watched part numbers). The previous design's concurrent fetch of every product page leaves the hot path. The buyability endpoint and grid are both verified to return in about a second.
- **Listing detection from the grid.** The set of part numbers present in the grid is diffed against the prior pass. A wanted part number newly present is a listing event. The grid poll also merges discoveries into the durable universe, so the separate 30-minute discovery loop is removed; discovery and listing detection are one step.
- **Buyability from the authoritative flag.** The buyability endpoint returns a per-part `isBuyable` boolean, served fresh from origin (verified: no-store, origin-hit, not edge-cached), and is the same signal the storefront uses. A false-to-true transition is a buyable event. This replaces parsing the `schema.org` marker out of product-page HTML as the primary signal.
- **Session manager.** A small collaborator holds a cookie jar obtained from a single grid fetch and reuses a keep-alive connection. It refreshes the jar on expiry or on a rejected response. The buyability endpoint was verified to require only this lightweight jar, not a headless browser. This collaborator is injected into the check so a fake can replace it in tests.
- **Confirm-before-call.** A buyable event triggers one confirming re-check on the next poll before the phone call is placed. The listing SMS and the buyable SMS may fire on first observation; only the call waits for confirmation. This kills single-sample false calls at a cost of roughly one poll cycle.
- **Alert ladder, explicit.**
  - Listed (new wanted part number in grid): SMS.
  - Confirmed buyable (`isBuyable` true, confirmed by the re-check): phone call plus SMS.
  - While buyable (`isBuyable` stays true): reminder SMS every five minutes, no quiet hours, stopping immediately on a false reading. Reminders never re-call.
  - Calls fire for every buyable wanted part number; the prior high-priority call gate is dropped.
- **Cooldown retired.** Because `isBuyable` is authoritative and stable, the stability-baseline gate and one-hour cooldown introduced to suppress `schema.org` flapping are removed. A genuine sell-out-then-restock within the hour alerts again. The only remaining guard against noise is the single confirming re-check before a call.
- **Edge-triggered, re-armed by sell-out.** A verified false reading re-arms a part number so its next buyable window alerts fresh, preserving the existing transition semantics.
- **Heavy page fetch demoted to fallback verifier.** The product-page buyability parser is retained but off the hot path, available as a second opinion (for example, to confirm before a call if the cheap signal is ever missing or contradictory).
- **Resilience and politeness.** A grid failure does not block the buyability call and vice versa. A mass-failure alarm fires when a surface returns failures or blocked responses across the board in a pass. Polling uses browser-like headers, jitter, and backoff on rejection, carrying forward the existing fetcher hardening.
- **Observability.** Listing events, buyability flips, confirming re-checks, alerts, reminders, and Apple's per-response timing and cache markers are written to the append-only event log. Each part number retains a first-detected-at timestamp for head-to-head latency comparison.
- **Endpoint fragility is accepted and contained.** The buyability and grid surfaces are undocumented and could change. They are reached only through the fetcher and parser seams, so a path or shape change is a localized fix, and the fallback verifier provides a safety net.

## Testing Decisions

Tests assert external behaviour: which alerts fire, in what order, what is persisted, what is fetched, and what the parsers return. No test asserts on thread internals, sleep timing, cookie internals, or private state shape beyond the persisted JSON contract. No test touches apple.com; grid HTML and buyability JSON come from committed fixtures.

Modules and behaviours under test, through the confirmed seams:

- **Buyability-message parser**, as a direct unit seam: a captured JSON fixture maps each part number to its buyable flag, including the all-false, mixed, and all-true cases, plus a malformed-body case.
- **Listing detection** through the fake-fetcher seam: a new wanted part number appearing between two grid fixtures produces exactly one listing event and one listing SMS, and merges into the universe.
- **Buyability ladder** through the fake-fetcher and injected-clock seams: a false-to-true flip produces a buyable SMS, withholds the call until the confirming re-check, then places the call; a single-sample true that reverts on the re-check produces no call.
- **Reminder cadence** through the injected clock: reminders repeat at the configured interval while buyable and stop on the first false reading, and never trigger a second call.
- **Resilience**: a failing grid fetch still allows a buyability call and vice versa; a surface failing across the board raises the mass-failure alarm; an empty store does not.
- **Session manager** through an injected fake: an expired or rejected session triggers a refresh and the pass still completes.
- **Re-arm semantics**: sell-out then restock within the former cooldown window alerts again.

Prior art: the existing Minitest suite already drives every one of these seams. `FakeFetcher` returns bodies by URL (string bodies, so JSON fixtures fit without change), `FakeTwilioClient` and `FakeAlerter` capture alert attempts, the injected `now` lambda and fake sleeper drive timing, and `with_state_store`/`with_event_log` use temp directories. New tests extend that file and pattern; new fixtures (a captured buyability JSON, an updated grid with an added tile) follow the existing fixture style.

## Out of Scope

- Any checkout, add-to-bag, login, or payment automation. Buying stays manual.
- The status page redesign. It follows separately using the existing UI brief, once these events exist.
- Headless browsers, Playwright, Node, or any frontend build tooling. Verified unnecessary: a lightweight cookie jar suffices.
- The `fulfillment-messages` endpoint. Verified to require Apple's full shield token and return blocked responses otherwise; the lighter buyability endpoint is used instead.
- Cache-busting freshness experiments. Verified unnecessary: the buyability endpoint is already origin-fresh on every request.
- Telegram or other new channels in production; Telegram stays on the separate Raspberry Pi watcher.
- SQLite or any database. JSON and JSON Lines remain sufficient.
- Multi-country watching as a feature. Configuration must not hardcode Canada, but only the Canadian store is exercised.
- Open-source packaging, naming, and licensing.

## Further Notes

- Every claim here was verified against Apple's live responses on 2026-06-10: the buyability endpoint returns all watched part numbers in roughly 800 bytes and about one second, origin-fresh, returning true for live grid inventory and false for sold-out parts, and tolerated polling at two-second intervals; the grid bootstrap parses cleanly and carries the full catalogue; the family filter pages redirect to the full grid; `fulfillment-messages` returns a blocked response without the full shield token. Ruby's standard library supports keep-alive connections without an added gem.
- The dominant external risk is the undocumented endpoints changing shape or being shielded harder. The fallback verifier and the localized parser seam are the mitigations. If the buyability endpoint is ever blocked, the heavy product-page path can return to the hot path as a slower but functional fallback.
- The detection speed that matters is measured in seconds, and the race after detection is human reaction time. Reminder reliability and call confirmation therefore carry weight equal to raw cadence.
- This rebuild removes more than it adds: the per-SKU page fan-out, the thread pool on the hot path, the `schema.org` flap parser as primary signal, the separate discovery loop, and the flap-suppression cooldown all go away, replaced by two cheap polls and an authoritative flag.
