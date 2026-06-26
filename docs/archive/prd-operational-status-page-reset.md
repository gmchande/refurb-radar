# PRD: Operational Status Page Reset

Created: 2026-06-19
Status: ready-for-agent
Tracker: none configured; this file is the published PRD.

## Reset

This PRD replaces the earlier inventory-dashboard direction. Refurb Radar should
not become a broad refurb analytics product right now. The useful product is an
operational status page for the existing watcher.

The page should answer three questions:

1. Can I buy something I care about right now?
2. What am I watching?
3. When did we last see or alert on those watched things, only where the data is
   direct enough to state honestly?

The old dashboard language created fake precision. It mixed Apple refurb-grid
visibility, direct buyability, alert history, and inferred time windows into one
surface. That made the page feel more confident than the data deserves.

## Keep

- Production phone calls stay paused/off by default.
- Production SMS stays enabled.
- Local browser-open behavior stays separate from production SMS/call state.
- The watcher loop remains fast and boring.
- `InventorySnapshot` remains the read-model seam where it keeps
  `StatusPage` thinner.
- Watch criteria remain visible as the main "what am I watching?" surface.
- The product keeps a hard distinction between "listed on Apple's refurb page"
  and "directly buyable."
- Buy links render only for products with direct buyability evidence.
- Tests continue to prevent listed-only products from being called available or
  buyable.

## Remove Or Pause

- The production recent-listings table is removed.
- User-facing history language based on inferred intervals is paused.
- Duration-style refurb history is paused unless exact start/end evidence is
  available and the result is secondary to current status.
- Broad dashboard analytics, charts, forecasting, and category expansion are out
  of scope.
- MacBook Air, Vision Pro, all-category browsing, configuration drilldowns, and
  per-criteria notification policy are later-only work.

Internal code may keep names that support alert dedupe or state reconstruction,
but those names are not product terminology.

## User Stories

1. As the operator, I want the first screen to show current directly buyable
   matches, so I can act immediately.
2. As the operator, I want listed-only products described as listed, not
   available or buyable, so I do not mistake Apple's grid visibility for stock I
   can purchase.
3. As the operator, I want production calls off and SMS on, so alerts stay calm
   without going silent.
4. As the local buyer, I want browser-open alerts to remain separate, so my Mac
   can still open a buyable product page without changing production behavior.
5. As the operator, I want to see watcher health, last check, channel state, and
   data faults, so a quiet market is distinguishable from a broken process.
6. As the operator, I want to see active watch criteria in plain language, so I
   know what the watcher is checking.
7. As the operator, I want simple last-seen or last-alert facts only where they
   are directly supported, so the page does not imply precision it does not have.
8. As an agent, I want the status page to consume a small snapshot/read model, so
   rendering does not re-grow history math.

## Product Decisions

- **Operational page, not analytics dashboard.** The page should be dense,
  current, and action-oriented.
- **Buyable comes first.** Current direct buyability is the most important state.
- **Listed is not buyable.** Grid sightings may explain what the watcher saw, but
  they do not create Buy links or availability claims.
- **Channel state is explicit.** Calls, SMS, and browser-open are separate
  channels. Calls off does not stop checking and does not disable SMS.
- **Watch criteria are the durable surface.** The page should make current rules
  readable before exposing raw data or editing controls.
- **History stays modest.** Alert history is useful. Inferred market history is
  paused until the evidence model is stronger.
- **No new stack.** Ruby, JSON, and server-rendered HTML remain enough.
- **No checkout automation.** Purchasing remains manual.

## Acceptance Criteria

- Current buyable matches render near the top with Buy links.
- Listed-only products do not render Buy links and are not described as available
  or buyable.
- The recent-listings table is gone from production HTML.
- The page renders watcher health, last check, channel state, active criteria,
  data faults, and current buyable rows from `InventorySnapshot` plus existing
  status-page rule grouping.
- Calls can be disabled while SMS remains enabled.
- Browser-open state remains separate from production SMS/call state.
- Watch criteria still render with grouped configurations and truthful counts.
- User-facing HTML does not expose the internal `episode` term.

## Testing Decisions

- Keep high-level render tests around visible status-page behavior.
- Keep direct `InventorySnapshot` tests for watcher health, channel state,
  faults, drop rows, and watch summaries.
- Keep regression coverage for listed-only products not being called buyable.
- Keep regression coverage for calls off, SMS on, and browser-open separation.
- Remove tests that assert the old recent-listings table or inferred duration
  rows.
- Do not add live Apple requests or browser automation.

## Out Of Scope

- Broad inventory analytics.
- Charts, forecasting, price modeling, and arrival prediction.
- MacBook Air, Vision Pro, or all-category expansion.
- Configuration detail pages or SKU drilldowns beyond the existing watch
  criteria grouping.
- Per-watch notification policy.
- Roda, Rails, SQLite, Node, Playwright, or a frontend build chain.
- Checkout, add-to-bag, login, payment, or Apple account automation.
