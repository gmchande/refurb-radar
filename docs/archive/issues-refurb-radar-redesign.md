# Issues: Refurb Radar Redesign

Created: 2026-06-10
Parent PRD: `docs/archive/prd-refurb-radar-redesign.md`
Status: archived
Tracker: none configured; this doc is the issue list. Issues are numbered in dependency order. Issues 2, 4, and 7 have no blockers and can run in parallel.

---

## Issue 1 — Ops recovery: restore Twilio sender, clean prod env, lock local lane to browser-open

Type: HITL
User stories: 3, 22

### What to build

No code. Restore production alert delivery and separate the two watcher lanes. Production alerts by Twilio SMS and call; the local Mac watcher alerts only by opening the product page in the browser.

- Purchase or verify a Twilio sender number and update the production secret.
- Send a production test alert and confirm both SMS and call arrive.
- Remove the temporary Mac Pro model inclusion from the production deploy environment.
- Confirm the local LaunchAgent environment carries no Twilio credentials and has browser-open alerts enabled.

### Acceptance criteria

- [ ] A production test alert delivers both an SMS and a call to the configured number.
- [ ] The production deploy environment no longer includes the extra Mac Pro model override.
- [ ] The local watcher, restarted via launchd, alerts only by browser-open; no Twilio attempt appears in its logs.
- [ ] Production worker is redeployed and its state shows checks resuming.

### Blocked by

None - can start immediately.

---

## Issue 2 — Declarative targets file replaces hardcoded matcher constants

Type: AFK
User stories: 8, 24

### What to build

Move the wanted-configuration rules out of code into a committed targets config file: a list of rules, each with model family, minimum unified memory, and allowed storage range. The matcher loads rules from this file; the existing environment-variable override for extra models remains as a testing knob. Editing the file changes what the watcher hunts without a code change.

### Acceptance criteria

- [ ] A committed targets file expresses the current rules: Mac mini and Mac Studio, 48GB+ unified memory, storage up to 2TB.
- [ ] The matcher's eligibility decisions are driven by the file; the hardcoded constants are gone.
- [ ] The extra-models environment override still works and is covered by a test.
- [ ] Unit tests cover rule parsing, eligibility for each rule field, and a malformed-file failure mode.
- [ ] A single check pass run against fixtures honours an edited rules file.

### Blocked by

None - can start immediately.

---

## Issue 3 — Durable SKU universe store with committed seed and canonical URLs

Type: AFK
User stories: 1, 4, 9, 25

### What to build

A persisted SKU universe: every part number ever observed, with family, memory, capacity, title, price, source, and first/last seen timestamps. The universe only grows; merges happen by part number. Each entry derives its watch URL from the part number alone (the short product URL form). The wanted set is the universe filtered by the targets rules, and it feeds the check pass from cold start.

Build the initial committed seed from the current refurb grid, sibling-variant expansion of one Mac mini and one Mac Studio product page, and cross-check completeness against the part numbers in the RefurbPing alert emails preserved in the failure-review packet.

### Acceptance criteria

- [ ] Universe store persists as JSON, merges by part number, and never loses entries across loads.
- [ ] A committed seed covers the full current Mac mini and Mac Studio refurb SKU families, verified against the RefurbPing email part numbers.
- [ ] Watch URLs are derived from part numbers, not stored marketing URLs.
- [ ] With empty runtime state, a check pass watches every seeded wanted SKU on its first pass.
- [ ] Tests cover universe growth from grid and variant fixtures, merge-by-part-number, and wanted-set filtering through the targets rules.

### Blocked by

- Issue 2 (targets rules define the wanted set).

---

## Issue 4 — Grid-independent direct lane with per-part-number dedupe

Type: AFK
User stories: 11, 13

### What to build

Make direct SKU checks unconditional. A grid fetch failure logs a warning and the pass continues through every direct watch URL; today it aborts the pass. Deduplicate candidates by part number before buyability verification so a SKU listed by both the grid and the direct lane is fetched and verified once per pass. Preserve existing alert semantics: edge-triggered, one alert per buyable window, re-armed by a verified not-buyable observation.

### Acceptance criteria

- [ ] With the grid fetch raising an error, the pass still checks all direct watch URLs and can alert.
- [ ] Each unique part number is fetched and verified at most once per pass, asserted via fake-fetcher call counts.
- [ ] Existing transition tests (dedupe of continuously buyable, re-alert after disappearance) still pass.
- [ ] The grid failure surfaces as a warning in the pass result, not a fatal error.

### Blocked by

None - can start immediately.

---

## Issue 5 — Concurrent PDP fetching with measured pass duration and cadence

Type: AFK
User stories: 12, 19

### What to build

Fetch product pages in the check pass on a small bounded thread pool (default around 6, environment-tunable), reusing existing timeouts. Record pass duration and effective cadence in the pass summary and persisted stats so cadence drift is measurable from logs and state rather than inferred.

### Acceptance criteria

- [ ] Pass results are identical to serial execution for the same fixture inputs.
- [ ] Concurrency is bounded and environment-tunable; one slow URL does not serialize the rest.
- [ ] Pass duration appears in the log line and persisted check stats.
- [ ] Tests assert one fetch per unique URL and correct results through the fake-fetcher seam, without asserting on thread internals.

### Blocked by

- Issue 4 (same code area; lands on the restructured pass).

---

## Issue 6 — Two-loop split: discovery becomes the slow loop, fast loop polls only wanted SKUs

Type: AFK
User stories: 2, 10

### What to build

Separate the cadences. The fast loop polls only wanted-SKU product pages on a jittered ~30 second cadence and is the only path that fires alerts. The slow loop, on a 15-30 minute interval, fetches the refurb grid, family grid pages, and product-page sibling-variant data, merging discoveries into the universe. New universe entries matching the targets rules join the fast loop on its next pass. A discovery failure logs and never delays or blocks the fast loop.

### Acceptance criteria

- [ ] The fast loop fetches only wanted-SKU pages; the grid is not fetched on the fast path.
- [ ] Discovery failures (grid or seed pages erroring) leave the fast loop's behaviour and timing unchanged.
- [ ] A SKU discovered by the slow loop and matching the rules is checked by the fast loop on its next pass.
- [ ] Effective fast-loop cadence with ~25 wanted SKUs stays in the 30-45 second class in a timed fixture run.
- [ ] Tests cover loop independence, discovery merge, and promotion of new matches.

### Blocked by

- Issue 3 (universe store), Issue 4 (grid-independent pass).

---

## Issue 7 — Append-only event log: check passes and buyability verdicts with signals

Type: AFK
User stories: 15, 23, 26

### What to build

A JSON Lines event log alongside the live-state JSON. Each check pass appends a pass-summary event; each buyability verification appends a verdict event with part number, verdict (buyable, not buyable, ambiguous), and the positive and negative signals observed. Retention is capped by event count so the file stays small. This makes "did we miss X, and why" answerable from data: not watched, checked late, parser miss, or delivery failure.

### Acceptance criteria

- [ ] A check pass appends a pass-summary event and one verdict event per verified SKU.
- [ ] Verdict events record the signals that produced the verdict.
- [ ] The log is capped: writing past the retention limit drops the oldest events.
- [ ] The log is append-only JSON Lines, readable line-by-line with standard tools.
- [ ] Tests cover event shape, per-pass counts, and retention behaviour against temporary files.

### Blocked by

None - can start immediately.

---

## Issue 8 — Alert attempt receipts and per-SKU/channel retry with backoff

Type: AFK
User stories: 14, 16, 21

### What to build

Record every alert attempt as an event: part number, channel, success, provider id, and error. A failed channel attempt retries on subsequent passes with per-SKU, per-channel backoff and a retry cap, so a transient Twilio error recovers and a persistent one does not flood. A SKU is marked alerted only by channel success, preserving the existing rule; partial success (call delivered, SMS failed) is visible in the receipts.

### Acceptance criteria

- [ ] Every attempt, success or failure, appends an attempt event with channel, outcome, provider id or error.
- [ ] A failed channel retries on later passes with backoff and stops at the cap; an eventual success marks the SKU alerted.
- [ ] A provider failure pattern (such as an invalid sender number) is identifiable from receipts alone, without reading process logs.
- [ ] Tests drive retry timing with the injected clock and the fake Twilio client; no real network.

### Blocked by

- Issue 7 (event log carries the receipts).

---

## Issue 9 — Polite fetching and the mass-failure tripwire

Type: AFK
User stories: 17, 18

### What to build

Make the fetcher look and behave like a considerate browser client: browser-like User-Agent and headers, jittered scheduling, and exponential backoff on 403, 429, and 5xx responses. Add the tripwire: when the majority of product checks in one pass fail or return ambiguous verdicts, emit a loud alarm event and log line, because that pattern means Apple is blocking the watcher, not that the store is empty. Today that failure mode is silent and looks like permanent out-of-stock.

### Acceptance criteria

- [ ] Requests carry browser-like headers; the bot-flavoured User-Agent is gone.
- [ ] Repeated 403/429/5xx responses trigger exponential backoff on subsequent fetches.
- [ ] A pass where most verifications fail or go ambiguous emits an alarm event distinct from ordinary warnings.
- [ ] A healthy pass with a genuinely empty store does not trip the alarm.
- [ ] Tests cover backoff scheduling with the injected clock and tripwire thresholds through the fake-fetcher seam.

### Blocked by

- Issue 7 (alarm is an event).

---

## Issue 10 — Deploy redesign to production and verify coverage, cadence, and delivery

Type: HITL
User stories: 1, 2, 20 (data side)

### What to build

Deploy the redesigned watcher with Kamal and verify it against reality. Confirm cold-start coverage (every seeded wanted SKU watched on the first pass), effective cadence in the 30-45 second class, receipts flowing to the event log, and alert delivery end-to-end. Then judge it against the next real restock wave: every RefurbPing email for a wanted configuration should correspond to a watcher detection and delivered alert, or to a receipt that explains exactly which layer failed.

### Acceptance criteria

- [ ] Production state shows the full seeded wanted set under watch from the first pass after deploy.
- [ ] Logged pass durations put effective cadence in the 30-45 second class.
- [ ] A live test alert produces SMS and call receipts in the event log.
- [ ] After the next restock wave, each RefurbPing match for a wanted configuration maps to a watcher alert or to a receipt identifying the failing layer.
- [ ] No tripwire alarms during steady-state operation.

### Blocked by

- Issues 1, 3, 5, 6, 8, 9.
