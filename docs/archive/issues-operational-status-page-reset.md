# Issues: Operational Status Page Reset

Created: 2026-06-19
Parent PRD: `docs/prd-operational-status-page-reset.md`
Status: active cleanup list
Tracker: none configured; this doc is the single-file issue list.

## Cross-cutting Constraints

- Preserve the fast watcher loop.
- Keep Ruby, JSON, and server-rendered HTML.
- Do not add checkout, add-to-bag, login, payment, Apple account, or purchase
  automation.
- Do not add Node, Playwright, Rails, Roda, SQLite, or a frontend build chain.
- Keep "listed on Apple's refurb page" separate from "directly buyable."

## Active Issue 1 — Inventory snapshot seam

Status: complete

`InventorySnapshot` now carries the current top-level read-model facts used by
the status page: generated time, watcher health, last check, watch summary,
channel state, drop rows, data faults, active products, and scoped event/history
inputs.

Keep this seam. Do not put new history reconstruction into the renderer unless a
small display helper is enough.

## Active Issue 2 — Calm channel policy

Status: complete

Production SMS remains enabled and phone calls remain off by config. Local
browser-open stays separate from production SMS/call behavior.

Acceptance coverage to preserve:

- Calls can be off while SMS remains on.
- Browser-open is shown as its own channel.
- The test-alert copy does not promise a phone call when calls are off.
- Disabling calls does not imply the watcher stopped checking.

## Active Issue 3 — Production status page reset

Status: complete

Remove the confusing analytics table and keep the production page operational.
The first screen should prioritize:

- Current directly buyable matches with Buy links.
- Watcher health and last check.
- SMS, call, and browser-open channel state.
- The active watch criteria and truthful grouped counts.
- Data problems when state, catalog, targets, or event inputs cannot be read.

Acceptance criteria:

- The old recent-listings section is absent from rendered HTML.
- Listed-only products are not described as available or buyable.
- Buy links render only for directly buyable products.
- Watch criteria still render.
- The rendered HTML does not expose the internal `episode` term.
- `ruby test/refurb_radar_test.rb` passes.

## Active Issue 4 — Truthful per-watch last facts

Status: later

Add simple "last seen" and "last alerted" facts to each watch criterion only
where the backing data is direct enough to state without inference. This should
be secondary to current buyability and channel health.

Acceptance criteria before starting:

- Define the exact source field for each displayed fact.
- Avoid inferred durations.
- Avoid blending grid visibility with direct buyability.
- Keep facts per watch criterion rather than as a broad analytics table.

## Paused Or Deleted From The Old Queue

The following old dashboard issues are intentionally not active:

- Recent listings table.
- Configuration detail pages and SKU drilldowns.
- Exact Mac mini GPU criteria.
- Per-criteria notification policy.
- MacBook Air pilot.
- Vision Pro or all-category expansion.
- Charts, forecasting, and broad inventory analytics.
- Roda or other web-framework review.

Revive any of these only with a fresh PRD that explains the exact operator
question, the source data, and why the current operational page is not enough.
