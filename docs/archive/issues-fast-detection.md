# Issues: Fast Detection Rebuild

Created: 2026-06-10
Parent PRD: `docs/archive/prd-fast-detection.md`
Status: archived; Issues 1-9 implemented; Issue 10 was HITL for deploy and live restock verification
Tracker: none configured; this doc is the issue list. Issues are numbered in dependency order. Issues 1 and 2 have no blockers and can run in parallel; 5, 6, and 7 are independent branches off issue 3.

All endpoint behaviour referenced here was verified against Apple's live responses on 2026-06-10 (see parent PRD, Further Notes).

---

## Issue 1 — Buyability-message parser with captured JSON fixtures

Type: AFK
User stories: 4, 15, 27

### What to build

A parser that turns Apple's buyability endpoint response into a part-number to buyable-flag map. The endpoint returns one JSON body covering every requested part number; the parser extracts each part's authoritative `isBuyable` boolean. This is the unit that replaces reading the flapping page marker.

Capture real response bodies as committed fixtures for the all-false, mixed, and all-true cases, plus a malformed body.

Shape of the response (captured from the live endpoint):

```
{"head":{"status":"200"},"body":{"content":{"buyabilityMessage":{
  "sth":{"G1JV8LL/A":{"isBuyable":false},"G1CD5LL/A":{"isBuyable":true}},
  "order":["sth"]}}}}
```

### Acceptance criteria

- [x] Parser maps each part number in the response to its buyable boolean.
- [x] All-false, mixed, and all-true fixtures parse to the correct map.
- [x] A malformed or empty body raises the project's parse error rather than crashing or returning a false negative silently.
- [x] A part number absent from the response is distinguishable from one present-and-false.
- [x] Unit tests cover every case against committed fixtures; no network.

### Blocked by

None - can start immediately.

---

## Issue 2 — Session manager: cookie jar from grid fetch, keep-alive, injectable

Type: AFK
User stories: 14, 22, 27

### What to build

A small collaborator that establishes a session against Apple's store by fetching the refurb grid once, holds the resulting cookie jar, and reuses a keep-alive connection for subsequent requests. It refreshes the jar when a request is rejected or the session has expired. The buyability endpoint was verified to need only this lightweight jar, no headless browser. The collaborator is injected into the check so a fake can replace it in tests.

### Acceptance criteria

- [x] A first use obtains a jar from a single grid fetch and reuses it for later requests.
- [x] A rejected or expired session triggers one refresh, and the in-flight pass still completes.
- [x] Requests reuse a keep-alive connection per host rather than reconnecting each call.
- [x] Polling carries browser-like headers and jitter and backs off on rejection (carries forward existing fetcher hardening).
- [x] The collaborator is injectable; a fake stands in for it in tests with no network.

### Blocked by

None - can start immediately.

---

## Issue 3 — Buyability poll replaces the per-SKU page fan-out as the primary buyable signal

Type: AFK
User stories: 4, 15, 17, 23

### What to build

Make the authoritative buyability flag the primary buyable signal. Each pass issues one buyability call covering all watched part numbers (verified: roughly 800 bytes, about one second, origin-fresh) and derives each part's buyable state from the returned flag. The previous concurrent fetch of every product page leaves the hot path. The product-page buyability parser is retained but demoted to a fallback verifier, available when the cheap signal is missing or contradictory. Existing edge-triggered alert semantics (buyable transition, re-arm on sell-out) are preserved on top of the new signal.

### Acceptance criteria

- [x] A pass confirms buyability for the whole watchlist via a single buyability call, not per-SKU page fetches.
- [x] A false-to-true flag transition is treated as a buyable event; a verified false re-arms the part.
- [x] The per-SKU page fan-out and its hot-path thread pool are gone; the page parser remains reachable as a fallback verifier.
- [x] A buyability call failure does not abort the pass (detection via the other surface still runs).
- [x] Tests drive the flag through the fake-fetcher seam (JSON fixture bodies) and assert buyable events and re-arm behaviour; no network.

### Blocked by

- Issue 1 (parser), Issue 2 (session for the call).

---

## Issue 4 — Grid poll as listing detector and universe growth; retire the discovery loop

Type: AFK
User stories: 1, 2, 3, 16

### What to build

Poll the refurb grid bootstrap each pass and diff its part-number set against the prior pass. A wanted part number newly present is a listing event that fires the first SMS. The same poll merges discoveries into the durable universe, so the separate 30-minute discovery loop is removed: listing detection and discovery become one cheap step. A grid failure does not block the buyability call.

### Acceptance criteria

- [x] A wanted part number appearing between two grid fixtures produces exactly one listing event and one listing SMS.
- [x] The grid poll merges newly seen parts into the universe; the standalone discovery loop is removed.
- [x] A part already present (not newly listed) produces no listing event.
- [x] A grid fetch failure leaves the buyability poll and its alerts unaffected.
- [x] Tests cover newly-listed detection, no-op on already-present parts, and universe merge through the fake-fetcher seam.

### Blocked by

- Issue 2 (session for the grid fetch).

---

## Issue 5 — Confirm-before-call and drop the high-priority call gate

Type: AFK
User stories: 5, 6, 10

### What to build

Gate the phone call on a confirming re-check: a buyable event places the call only after the buyable flag is still true on the next poll. The listing SMS and buyable SMS may fire on first observation; only the call waits one cycle. Remove the prior restriction that limited calls to high-priority configurations, so every buyable wanted part number rings.

### Acceptance criteria

- [x] A flag that is true on two consecutive polls places the call; a single-sample true that reverts on the re-check places no call.
- [x] The buyable SMS fires on first observation, before the confirming poll.
- [x] Every buyable wanted part number is call-eligible; the high-priority gate is gone.
- [x] A placed call still records its receipt and marks the part alerted.
- [x] Tests drive two-poll confirmation and single-sample reversion through the injected clock and fake Twilio client; no network.

### Blocked by

- Issue 3 (buyable signal).

---

## Issue 6 — Reminder ladder: 5-minute SMS while buyable, stop on sell-out

Type: AFK
User stories: 7, 8, 9, 13

### What to build

While a part stays buyable, send a reminder SMS every five minutes (configurable), at any hour, until it sells out. The first false reading stops reminders immediately. Reminders never place a second call and are distinct from the one-time listing and buyable alerts.

### Acceptance criteria

- [x] A part that stays buyable produces a reminder at each interval after the initial buyable alert.
- [x] The interval is configurable; reminders fire regardless of time of day.
- [x] A verified false reading stops reminders on that pass.
- [x] Reminders are SMS-only and never trigger a call.
- [x] Tests drive reminder timing and stop-on-sell-out through the injected clock; no network.

### Blocked by

- Issue 3 (buyable signal).

---

## Issue 7 — Retire the flap cooldown; re-arm on sell-out via the authoritative flag

Type: AFK
User stories: 12, 24

### What to build

Remove the stability-baseline gate and one-hour availability cooldown that existed to suppress page-marker flapping. With the authoritative flag as the signal, a sell-out followed by a restock within the former cooldown window alerts again immediately. The only retained noise guard is the single confirming re-check before a call (issue 5).

### Acceptance criteria

- [x] The stability-baseline and one-hour cooldown logic are removed.
- [x] A part going buyable, selling out, and going buyable again within the former cooldown window produces a fresh buyable alert each time.
- [x] No regression in once-per-window alerting for a part that simply stays buyable.
- [x] Tests cover the rapid sell-out-then-restock case through the injected clock; no network.

### Blocked by

- Issue 3 (buyable signal).

---

## Issue 8 — Observability: ladder events, server-timing, first-detected-at

Type: AFK
User stories: 18, 19, 20

### What to build

Record the full ladder to the append-only event log: listing events, buyability flips, confirming re-checks, alerts, and reminders, each timestamped. Capture Apple's per-response timing and cache markers (`server-timing`, cache-hit/miss) per poll so read freshness and speed are measurable. Retain a first-detected-at timestamp per part number for head-to-head latency comparison against a third-party email.

### Acceptance criteria

- [x] Each ladder stage appends a distinct, timestamped event.
- [x] Per-poll Apple timing and cache markers are recorded.
- [x] Each part retains its first-detected-at timestamp across passes.
- [x] The log stays append-only and bounded by the existing retention cap.
- [x] Tests assert event shape and first-detected-at retention against temp files; no network.

### Blocked by

- Issue 3, Issue 4 (events observe both surfaces).

---

## Issue 9 — Cross-surface resilience and mass-failure alarm for the new surfaces

Type: AFK
User stories: 17, 21

### What to build

Ensure one surface failing cannot blind the other, and raise a loud alarm when a surface fails or returns blocked responses across the board in a pass, so a bot block reads as an outage rather than an empty store. Extends the existing mass-failure alarm to the grid and buyability surfaces.

### Acceptance criteria

- [x] A grid failure still allows the buyability poll and its alerts; a buyability failure still allows listing detection.
- [x] A surface returning failures or blocked responses across the board in a pass raises the mass-failure alarm.
- [x] A genuinely empty store (successful poll, nothing buyable) does not raise the alarm.
- [x] The alarm is a distinct event, not an ordinary warning.
- [x] Tests cover each-surface-down, all-blocked, and empty-store cases through the fake-fetcher seam.

### Blocked by

- Issue 3, Issue 4 (guards both surfaces).

---

## Issue 10 — Deploy the fast-detection rebuild and verify head-to-head

Type: HITL
User stories: 1, 20

### What to build

Deploy the rebuilt watcher with Kamal and verify it against reality. Confirm the two-surface fast loop runs on its ~10-second cadence, listing and buyable events flow with receipts, and the call fires only after confirmation. Then judge it against the next real restock wave: each third-party email for a wanted configuration should correspond to an equal-or-earlier watcher detection, provable from the first-detected-at timestamps.

### Acceptance criteria

- [ ] Production runs the two-surface fast loop at the intended cadence with both polls succeeding.
- [ ] A live buyable event produces a confirmed call plus SMS, with receipts in the event log.
- [ ] Reminders arrive at the configured interval while a part stays buyable and stop on sell-out.
- [ ] After the next restock wave, each third-party match maps to an equal-or-earlier watcher detection by timestamp, or to a receipt identifying the failing layer.
- [ ] No mass-failure alarms during steady-state operation.

### Blocked by

- Issues 5, 6, 7, 8, 9.
