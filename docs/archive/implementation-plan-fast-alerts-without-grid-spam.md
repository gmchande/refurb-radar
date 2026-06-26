# Implementation Plan: Fast Alerts Without Grid Spam

Created: 2026-06-17
Status: archived
Supersedes: the grid-first alert assumption in `docs/archive/prd-fast-detection.md`

## Goal

Keep Refurb Radar fast for known watched SKUs, while stopping stale or flapping
refurb-grid listings from sending repeated SMS messages after the product is no
longer actually buyable.

The immediate rollout is deliberately narrow:

1. Ship grid/listing flap suppression.
2. Preserve immediate SMS and local alerting on the first direct
   `isBuyable:true` signal.
3. Keep phone calls buyability-led and confirmation-based.
4. Add lightweight first-surface observability so the next real drops show
   whether grid, buyability, or another surface wins.
5. Revisit OR-style first-alert semantics only after production evidence shows
   they buy meaningful speed.

This plan is SKU-first. Refurbished products should be configured through known
SKUs or friendly rules that compile to known SKUs. Unknown SKU discovery remains
catalog maintenance, not an urgent alert path, unless a future explicit opt-in
is added.

## Diagnosis

The previous fast-detection design treated the refurb grid as the listing event
surface and the buyability endpoint as the authoritative checkout surface. That
was useful, but it included an unproven assumption: that grid presence is where
a product appears first.

Production evidence from the June 17 incident does not support building a
larger OR ladder yet:

- For `G1CD9LL/A`, `G1CD6LL/A`, and `FU973LL/A`, the buyability endpoint first
  returned buyable at `2026-06-17T18:42:23Z`.
- Production sent the first buyable SMS at `2026-06-17T18:42:23Z`.
- Production placed the confirming phone call at `2026-06-17T18:42:38Z`.
- Repeated later SMSes were `listing` alerts from grid reappearances while
  buyability was already false.
- For `G1CD6LL/A`, the first observed grid listing event in that incident came
  at `2026-06-17T18:48:40Z`, more than six minutes after buyability first
  returned true.

The proven bug is narrower than the larger ladder idea:

- `StateStore#alertable_candidates` treated a single grid miss followed by
  presence as a fresh `listing` edge.
- Apple's grid can flap for out-of-stock products.
- Production therefore sent repeated listing SMSes, even though buyability was
  false.

The fix is to keep direct buyability aggressive, but make grid/listing re-arm
require stable absence.

## Current Alert Procedure

### Direct buyability

When a watched SKU has `isBuyable:true`:

- Send the first SMS immediately.
- Open locally immediately where the local LaunchAgent is configured to do so.
- Record the buyable timestamp.
- Schedule phone confirmation.

On the next buyable pass:

- Place the phone call if call confirmation is enabled.

While the SKU remains buyable:

- Send reminders only on the reminder cadence.
- Re-ring calls only on the call cadence.

When present-and-false buyability remains stable:

- Stop reminders and calls.
- Re-arm the buyable alert state.

### Refurb grid/listing

When a watched SKU appears in the refurb grid:

- A listing SMS may be sent as a weaker signal.
- It must be source-labelled as listing/grid, not confirmed buyable.
- It must not place a phone call.
- It must not cause buyable reminders.

When the grid briefly misses the SKU:

- Do not re-arm the listing SMS.

Only after stable grid absence:

- Clear the listing alert state so a later grid reappearance can alert again.

This explicitly supersedes the old no-cooldown/no-re-arm-delay decision for
grid/listing alerts only. Direct buyability stays immediate because that is the
signal most likely to matter for checkout.

### Availability/PDP fallback

Existing fallback availability signals stay conservative:

- They are not a phone-call source.
- They must not delay a later direct buyability SMS.
- Cached or hydrated page states must be labelled as weaker than direct
  buyability.

## Implementation Plan

### Step 1: Ship grid flap suppression

Keep the local patch that adds:

- `listed_present`
- `last_listed_at`
- `last_not_listed_at`
- `not_listed_streak`
- `LISTING_STABLE_ABSENT_PASSES`

Behavior:

- A first grid listing can still alert.
- A one-pass absence followed by grid presence does not alert again.
- A stable absence followed by grid presence does alert again.

This is the production spam fix.

### Step 2: Add lightweight first-surface observability

Do not introduce a broad alert-cycle state migration yet. Keep the existing JSON
shape and add only passive fields to each current record:

- `first_positive_source`
- `first_positive_at`
- `first_buyability_true_at`
- `first_grid_present_at`
- `first_availability_signal_at`

Set these fields the first time the corresponding source is positive in the
current alert cycle.

Clear them only when existing re-arm rules say the opportunity is over:

- stable present-and-false buyability can clear buyability first-surface fields
  with the buyable alert state;
- stable grid absence can clear grid first-surface fields with the listing
  alert state;
- if all first-surface fields are gone, clear `first_positive_source` and
  `first_positive_at`.

This lets production answer which source appeared first without creating a new
state machine.

### Step 3: Make channel semantics explicit

Keep these rules in code and tests:

- First `isBuyable:true` sends SMS/local alert immediately.
- Phone call requires buyability evidence after the first buyable alert.
- Grid-only evidence can SMS once per stable grid alert cycle.
- Grid-only evidence never calls.
- Availability/PDP fallback evidence never delays a direct buyability SMS.
- Reminders require current buyability true.

This removes the ambiguity where a future "possible hit" rung might accidentally
delay the first direct buyability SMS.

### Step 4: Measure before OR semantics

After deployment, use state/events/status to inspect real drops:

- Which surface became positive first?
- How many seconds from first positive to SMS?
- How many seconds from first buyability true to call?
- Did grid report present while buyability reported false?
- Did any grid-only alert later become directly buyable?

Build an OR-style first alert only if measured drops show that grid or another
surface consistently beats buyability enough to justify giving weaker signals
more power.

### Step 5: Keep configuration SKU-first

Configuration should stay understandable to a person:

- choose explicit SKUs from the known catalog;
- define friendly criteria such as model, chip, memory, storage, and price;
- preview exactly which known SKUs a rule matches;
- show discovered-but-unwatched SKUs as maintenance data.

Do not urgently alert for surprise SKUs unless an explicit future setting opts
into that behavior.

## Test Plan

State-store tests:

- One grid-absent pass followed by grid-present does not re-alert.
- Stable grid absence followed by grid-present does re-alert.
- The grid-flap tests persist and reload state between passes.
- The grid-flap tests isolate listing behavior from not-buyable behavior.
- First grid presence records first-surface fields.
- First buyability true records first-surface fields.
- If grid presence happened first, later buyability records
  `first_buyability_true_at` without overwriting `first_positive_source`.
- First direct buyability still alerts immediately after an earlier weaker
  availability signal.
- Phone call never fires from grid-only evidence.
- Reminders only fire while current buyability is true.

Rollout checks:

- Run the full Minitest suite.
- Run production `bin/check-once` with alerts disabled if practical.
- Confirm only one worker is running.
- Confirm SMS and call test paths still work.
- Confirm state/event output records first-surface fields on the next positive
  production signal.

## Acceptance Criteria

- A known watched SKU with `isBuyable:true` sends an SMS on the first true pass.
- A known watched SKU with grid presence but buyability false sends at most one
  listing SMS per stable grid alert cycle.
- A phone call never fires from grid-only evidence.
- A phone call fires after buyability is true on a confirming pass.
- Reminders fire only while buyability is currently true.
- State records enough first-surface timing to decide later whether OR semantics
  are worth building.
