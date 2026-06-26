# PRD: Refurb Radar Redesign

Created: 2026-06-10
Status: archived
Tracker: none configured; this file is historical and no longer the active PRD.

## Problem Statement

I built a custom watcher to catch Apple Canada refurbished Mac mini and Mac Studio restocks, and it lost to a free email service. On 2026-06-10, RefurbPing emailed me every overnight and morning restock, including the 64GB configurations I wanted most. My watcher alerted me on three or four of them.

It failed in layers. The watcher only knew the SKUs it had already seen, so most Mac mini part numbers were not being watched when they restocked; it discovered them hours later, after the window closed. Its effective check cadence drifted to 70-120 seconds because every product page was fetched serially. A single grid fetch failure aborted the whole pass, including the direct product checks that matter most. And when the Twilio sender number broke, alerts died silently: nothing in the state, nothing on the status page, no way to tell a quiet market from a dead pipeline.

The status page compounded the problem. It showed counters instead of answering the only questions I have: is the watcher alive, what is buyable right now, did my alerts deliver, and what is it actually watching?

## Solution

Rebuild the watcher around a principle the failure made obvious: coverage must never depend on discovery. Apple part numbers are stable identifiers, product pages embed every sibling configuration of a family including out-of-stock ones, and a canonical product URL is derivable from a part number alone. So the full universe of SKUs I care about is enumerable ahead of time, and the watcher should hold it durably rather than learn it reactively.

The redesign splits the watcher into two independent loops. A fast loop polls only the wanted-SKU product pages, concurrently, on a jittered ~30 second cadence, and fires alerts on the not-buyable-to-buyable transition. A slow loop runs every 15-30 minutes to grow the SKU universe from the refurb grid, family pages, and sibling-variant expansion. A discovery failure costs freshness; it can never cost detection.

What I want becomes data instead of code: a declarative targets file (model family, minimum memory, storage range) matched against the universe, so new products, new configurations, and eventually other people's needs are a config change. Every alert attempt and every buyability verdict is recorded as an event with its outcome, so "did it miss X, and why" is answerable from the data. Channel failures become loud instead of silent. The production watcher alerts by Twilio SMS and call; my local Mac watcher keeps running the same code but only opens the product page in my browser.

## User Stories

1. As a refurb buyer, I want every SKU matching my criteria watched from the moment the watcher starts, so that a restock of a known configuration can never be missed because the watcher had not discovered it yet.
2. As a refurb buyer, I want the watcher to detect a buyable transition within about 30 seconds of it happening, so that I can beat other buyers to short restock windows.
3. As a refurb buyer, I want an SMS and a phone call when a wanted SKU becomes buyable, so that I am woken up or interrupted rather than finding an email later.
4. As a refurb buyer, I want the alert to include the part number, title, and direct product URL, so that I can open the page and add to bag in seconds.
5. As a refurb buyer, I want alerts only on confirmed buyability signals, so that I am never paged for a page that merely loads.
6. As a refurb buyer, I want exactly one alert per buyable window per SKU, so that a machine that stays in stock for an hour does not page me every 30 seconds.
7. As a refurb buyer, I want a fresh alert when a SKU sells out and later restocks, so that recurring inventory is treated as a new opportunity.
8. As the operator, I want my wanted configurations expressed in a declarative targets file, so that changing models, memory floors, or storage ranges is a config edit, not a code change.
9. As the operator, I want the SKU universe persisted durably and only ever growing, so that a restart or redeploy never shrinks coverage.
10. As the operator, I want discovery to keep enriching the universe from the grid, family pages, and sibling-variant expansion, so that newly introduced configurations are picked up without my intervention.
11. As the operator, I want direct SKU checks to run even when the grid fetch fails, so that Apple page issues on one surface cannot blind the watcher on the surface that matters.
12. As the operator, I want product pages fetched concurrently with bounded parallelism, so that the effective cadence stays near 30 seconds as the watchlist grows.
13. As the operator, I want each SKU checked at most once per pass regardless of how many sources list it, so that passes stay fast and Apple sees no redundant traffic.
14. As the operator, I want every alert attempt recorded with channel, outcome, provider id, and error, so that I can distinguish "SKU never became buyable" from "alert failed to deliver".
15. As the operator, I want every buyability verdict recorded with its signals, so that a missed restock can be traced to the exact failing layer: not watched, checked late, parser miss, or delivery failure.
16. As the operator, I want failed alerts retried with per-SKU, per-channel backoff, so that a transient Twilio error does not permanently swallow an alert, and a persistent one does not spam retries.
17. As the operator, I want a loud alarm when most product checks fail or go ambiguous in a single pass, so that Apple bot-blocking looks like an outage instead of an empty store.
18. As the operator, I want the fetcher to send browser-like headers, jitter its timing, and back off on 403, 429, and server errors, so that the watcher stays under Apple's anti-bot thresholds.
19. As the operator, I want pass duration and effective cadence logged and visible, so that cadence drift is a measurable fact rather than a feeling.
20. As the operator, I want the status page to answer first whether the watcher is alive, what is buyable now, whether alert channels are healthy, and what it is watching, so that I can trust it at a glance.
21. As the operator, I want the status page to distinguish tracked from buyable and attempted from delivered, so that the page never overstates what happened.
22. As a local user, I want the same watcher running on my Mac with browser-open as its only alert channel, so that I get an instant on-screen lane without duplicate SMS or calls.
23. As the operator, I want state and events kept in small local JSON files, so that the system stays inspectable with a text editor and needs no database.
24. As a future user of other products, I want the watcher's product families, country store, and matching rules driven by configuration, so that watching MacBook Pros or another country's store is setup, not surgery.
25. As a potential open-source maintainer, I want secrets, personal targets, and seed catalogs separated from the engine, so that the project can be published without scrubbing my data out of the code.
26. As an agent working on this codebase, I want every new behaviour reachable through injected fakes and fixtures, so that the full detection and alerting pipeline is testable without touching apple.com.

## Implementation Decisions

- **Two-loop architecture.** A fast detection loop polls wanted-SKU product pages on a jittered ~30 second cadence and is the only path that fires alerts. A slow discovery loop (15-30 minute interval) fetches the refurb grid, family grid pages, and product-page sibling-variant data to grow the SKU universe. The loops share state but no failure modes; the fast loop runs even when discovery is broken.
- **Durable SKU universe.** A persisted store of every part number ever observed, with family, memory, capacity, title, price, source, and first/last seen timestamps. The universe only grows. A committed seed snapshot ships with the repo so cold start has full coverage; runtime discovery merges into it. Initial seed is built from the current grid, sibling expansion of one Mac mini and one Mac Studio product page, and cross-checked against the part numbers in the RefurbPing alert emails from 2026-06-10.
- **Declarative targets.** Matching rules move from hardcoded constants to a committed config file: list of rules with model family, minimum unified memory, and allowed storage range. The existing environment-variable override for extra models remains as a testing knob. The wanted set is the universe filtered by these rules.
- **Canonical URLs.** Each universe entry derives its watch URL from the part number alone (the short product URL form), so coverage never depends on remembering long marketing URLs.
- **Edge-triggered alerting, unchanged semantics.** Buyability confirmation rules stay as they are: schema.org InStock, enabled add-to-bag, or an explicit buyable flag; HTTP 200 alone never counts. Alerts fire on the not-buyable-to-buyable transition; a verified not-buyable observation re-arms the SKU.
- **Bounded concurrency.** Product-page fetches in the fast loop run on a small thread pool (default around 6, environment-tunable), reusing existing timeouts. Candidates are deduplicated by part number before buyability verification.
- **Polite fetching.** Browser-like User-Agent and headers, jittered scheduling, and exponential backoff on 403, 429, and 5xx responses. A tripwire raises a loud warning event when the majority of product checks in one pass fail or return ambiguous verdicts, since that pattern means blocking, not an empty store.
- **Event log.** An append-only JSON Lines log records check-pass summaries, buyability verdicts with their positive and negative signals, and alert attempts with channel, success, provider id, and error. The log is capped by retention count to stay small. Existing seen-state JSON remains the live-state store.
- **Alert retry policy.** A failed channel attempt retries on subsequent passes with per-SKU, per-channel backoff and a retry cap, so transient provider errors recover and persistent ones do not flood.
- **Channel configuration.** Production alerts via Twilio SMS and voice call only. The local Mac watcher runs the same code with browser-open as its only channel and no Twilio credentials in its environment. Telegram stays on the separate Raspberry Pi watcher and is out of scope here.
- **Operational prerequisites** (no code): restore a verified Twilio sender number and confirm with a test alert; remove the temporary Mac Pro model inclusion from the production deploy environment; verify the local LaunchAgent environment carries no Twilio credentials.
- **Status page sequencing.** The status page redesign happens after the event log exists, driven by the separate UI brief in the failure-review packet, because the page's core sections (alert delivery, coverage, cadence, recent failures) render data this PRD creates.

## Testing Decisions

Tests assert external behaviour only: what gets alerted, what gets persisted, what gets fetched, and what the rendered page says. No test inspects thread internals, sleep timing, or private state shapes beyond the persisted JSON contract. No test touches apple.com; all HTML comes from committed fixtures.

Modules under test, through existing seams:

- **Check pass** through the fake-fetcher seam (a URL-to-HTML map): fast loop completes when the grid fetch raises, each unique part number is fetched and verified once per pass, the mass-failure tripwire fires when most product fetches fail, and cadence stats are recorded.
- **Discovery and universe** through the same fake-fetcher seam with a temporary store: the universe grows from grid and variant fixtures, merges by part number, and never loses entries.
- **Target rules** as pure unit tests: rules-file parsing and eligibility decisions, replacing the current constant-based matcher tests.
- **Alert delivery and retry** through the fake Twilio client seam with an injected clock: attempt events are written with outcomes, failures retry with backoff, successes mark the SKU alerted.
- **State and event log** against temporary files: transition edge cases (the existing re-alert and disappearance tests are the prior art), attempt-event retention caps.
- **Status page** as render-from-JSON tests asserting on HTML content.

Prior art: the existing Minitest suite already runs every one of these seams with `FakeFetcher`, `FakeTwilioClient`, fixture grid and product pages, injected clocks, and a fake sleeper. New tests extend that file and pattern; new fixtures follow the existing fixture style.

## Out of Scope

- Any checkout, add-to-bag, login, or payment automation. Purchasing stays manual.
- The status page implementation itself: it follows as a separate pass using the UI brief, after the event data exists.
- Telegram or other new alert channels in production; Telegram remains on the Raspberry Pi watcher.
- SQLite or any database. JSON and JSON Lines stay until querying needs prove otherwise.
- Multi-country watching as a feature. Configuration must not hardcode Canada, but only the Canadian store is exercised.
- Open-source packaging, naming, documentation, and licence. The design keeps engine and personal data separable so that work stays cheap later.
- Headless browsers, Playwright, Node, or any frontend build tooling.

## Further Notes

- The full evidence trail (RefurbPing email screenshots, Twilio logs, production state inspection) lives in the failure-review packet under the repo's scratch directory, dated 2026-06-10. The diagnosis there is confirmed against the code; this PRD supersedes its improvement plan by replacing the static committed SKU list with the universe-plus-rules model.
- The dominant external risk is Akamai bot protection. The pixeljets write-up on scraping Apple's refurb store documents intermittent 403s; the tripwire and backoff decisions exist because of it. If blocking becomes persistent, cadence and concurrency are the knobs to lower first.
- Detection speed beyond ~30 seconds is not worth buying with anti-bot risk. The race after detection is human reaction time, which is why delivery reliability and channel health carry equal weight to cadence in this design.
- Two watcher instances currently poll Apple: production (Kamal) and the local LaunchAgent watcher, which launchd keeps alive. Per the channel decisions, both stay, with the local instance restricted to browser-open alerts.
