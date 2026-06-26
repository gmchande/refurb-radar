# Refurb Radar Implementation Plan

Status: archived

## Goal

Build a local macOS watcher that checks Apple Canada's refurbished Mac inventory
about every 30 seconds, filters for Mac mini or Mac Studio configurations with
48GB or more unified memory and 2TB or less SSD, confirms the product is
directly buyable, and immediately opens the product page in the user's browser.

The watcher must help the user buy manually. It must not add to bag, log in,
checkout, or automate payment.

## Verified Facts

Verification date: 2026-06-09, from the local experiments workspace.

The requested URL:

```text
https://www.apple.com/ca/shop/refurbished/mac/mac-mini-mac-studio
```

currently returns HTTP 301 to:

```text
https://www.apple.com/ca/shop/refurbished/mac
```

The canonical refurbished Mac page is server-rendered enough for a lightweight
poller. It contains:

```js
window.REFURB_GRID_BOOTSTRAP = { ... }
```

Relevant verified JSON paths:

- `tiles[]`
- `tiles[].title`
- `tiles[].partNumber`
- `tiles[].productDetailsUrl`
- `tiles[].filters.dimensions.refurbClearModel`
- `tiles[].filters.dimensions.tsMemorySize`
- `tiles[].filters.dimensions.dimensionCapacity`
- `tiles[].omnitureModel.customerCommitString`
- `dictionaries.dimensions.refurbClearModel`
- `dictionaries.dimensions.tsMemorySize`
- `dictionaries.dimensions.dimensionCapacity`

Fresh parse result at verification time:

```text
tiles=134
target_tiles=0
eligible_target_tiles=0
models=display,imac,macbookair,macbookpro,macmini,macpro,macstudio
```

That means Apple currently exposes Mac mini and Mac Studio as filterable models,
but there were no live Mac mini or Mac Studio grid tiles in the fetched page at
verification time.

Product detail pages expose direct buyability signals. A live refurbished iMac
PDP had:

```text
schema.org/InStock
enabled Add to Bag button
isBuyable: true
```

An unavailable Mac Studio PDP had:

```text
schema.org/OutOfStock
disabled Add to Bag button
isBuyable: false
```

This confirms the watcher should use the grid page to find target candidates and
the product detail page to confirm buyability before opening the browser.

Local runtime assumptions verified:

```text
ruby: local Ruby shim
open: /usr/bin/open
```

## Stack Choice

Use Ruby standard library only:

- `Net::HTTP` for HTTP fetches.
- `JSON` for state and parsed embedded data.
- `URI` for URL handling.
- `Time` for timestamps.
- `Open3` or argv-form `system` for calling `/usr/bin/open` and optional alert
  commands.
- `Minitest` for tests.

Heavier alternatives are not justified:

- No browser driver: Apple exposes the needed server-rendered data.
- No Node/Vite/React: there is no frontend product here.
- No database: a tiny JSON state file can track alerted SKUs.
- No Rails/Roda: no web app is needed.
- No auto-checkout tooling: the intended flow is human purchase after alert.

## Matching Rules

Target model:

- `macmini`
- `macstudio`

Target memory:

- 48GB or more.
- Examples: `48gb`, `64gb`, `96gb`, `128gb`, `192gb`, `256gb`.
- Parse the leading numeric amount in GB.
- Ignore unusual memory keys that cannot be parsed as GB unless tests document
  a safe interpretation.

Target storage:

- 2TB or less.
- Include: `128gb`, `256gb`, `512gb`, `1tb`, `1point5tb`, `2tb`.
- Exclude: `3tb`, `4tb`, `8tb`, `16tb`, and anything unknown.

Candidate tile must include:

- part number
- title
- absolute product URL
- model
- memory
- capacity
- price when present
- Apple commit string when present

## Buyability Confirmation

For every matching grid tile, fetch the product detail URL once before alerting.

Treat as buyable if at least one strong positive signal is present and no strong
negative signal is present.

Prefer structured PDP signals over loose text matching. The implementation
should parse schema.org JSON-LD and Apple `window.pageLevelData` fields first,
then fall back to the literal Add to Bag button only if the structured data is
missing.

Positive signals:

- `http://schema.org/InStock`
- `"isBuyable":true`
- `"buyable":true`
- `buyNowButton.disabled` is `false`
- the primary `data-autom="add-to-cart"` button exists without `disabled`

Negative signals:

- `http://schema.org/OutOfStock`
- `"isBuyable":false`
- `"buyable":false`
- `buyNowButton.disabled` is `true`
- the primary `data-autom="add-to-cart"` button exists with `disabled`
- customer commit string contains `Out of stock`

Initial implementation should require:

```text
positive_signal && !negative_signal
```

If the grid shows a matching tile but PDP verification is ambiguous, log it as
`candidate_unconfirmed` and do not open the browser. That prevents false
confidence during a purchase race.

## Polling Loop

Default poll target:

```text
https://www.apple.com/ca/shop/refurbished/mac
```

Default cadence:

```text
random 24..38 seconds
```

Reasoning:

- Close to the requested 30 seconds.
- Avoids a perfectly periodic access pattern.
- Keeps load low enough for a personal watcher.

Loop behavior:

1. Fetch canonical refurbished Mac page.
2. Extract `window.REFURB_GRID_BOOTSTRAP`.
3. Parse JSON.
4. Filter target candidates.
5. For each candidate, fetch PDP and confirm buyability.
6. If buyable and not already alerted in the current buyable appearance window:
   - write a high-visibility log line,
   - call any configured non-blocking secondary alert command,
   - call `/usr/bin/open` with the product URL as a separate argv argument.
7. Save current target and buyable SKU state.
8. Sleep with jitter.

## Dedupe and Re-alerting

Use a local JSON state file:

```text
state/seen.json
```

State shape:

```json
{
  "last_checked_at": "2026-06-09T16:48:05Z",
  "currently_seen": {
    "G1CE4LL/A": {
      "title": "Refurbished Mac Studio ...",
      "url": "https://www.apple.com/ca/shop/product/...",
      "first_seen_at": "2026-06-09T16:48:05Z",
      "last_seen_at": "2026-06-09T16:48:05Z",
      "last_buyable_at": "2026-06-09T16:48:06Z",
      "alerted_at": "2026-06-09T16:48:06Z"
    }
  },
  "history": []
}
```

Dedupe rule:

- Alert once per SKU while it remains continuously confirmed buyable.
- If a SKU disappears from target candidates and later returns buyable, alert
  again.
- If a SKU stays visible but changes from unconfirmed or out of stock to
  confirmed buyable, alert when that transition is detected.

This avoids reopening the same product every 30 seconds while preserving the
important flash-sale behavior.

## Files to Build

```text
AGENTS.md
CLAUDE.md
IMPLEMENTATION_PLAN.md
README.md
bin/check-once
bin/watch
bin/install-launch-agent
bin/uninstall-launch-agent
lib/refurb_radar.rb
lib/refurb_radar/fetcher.rb
lib/refurb_radar/parser.rb
lib/refurb_radar/matcher.rb
lib/refurb_radar/buyability.rb
lib/refurb_radar/state_store.rb
lib/refurb_radar/alerter.rb
test/refurb_radar_test.rb
test/fixtures/refurb_grid.html
test/fixtures/live_pdp.html
test/fixtures/out_of_stock_pdp.html
launchd/com.gaurav.refurb-radar.plist.erb
state/.gitkeep
log/.gitkeep
```

The implementation can start smaller than this if useful, but these boundaries
are the expected shape once the first working version is complete.

## Command Behavior

`bin/check-once`:

- Fetch once.
- Print summary:
  - total tiles
  - target tiles
  - eligible target tiles
  - confirmed buyable matches
  - any parser or verification warnings
- Exit 0 when the check completed, even if no products match.
- Exit non-zero for fetch, parse, or config errors.

`bin/watch`:

- Run the polling loop.
- Print one concise line per check.
- Open browser immediately when a confirmed match appears.
- Trap `INT` and `TERM` for a clean shutdown.

`bin/install-launch-agent`:

- Render a LaunchAgent plist into:

```text
~/Library/LaunchAgents/com.gaurav.refurb-radar.plist
```

- Use `launchctl bootstrap gui/<uid> ...` or `launchctl load` depending on the
  local macOS behavior.
- Start the watcher.

`bin/uninstall-launch-agent`:

- Stop the watcher.
- Remove the installed plist.
- Leave logs and state in the repo unless explicitly cleaned.

## Alerting

Primary alert:

```text
system("/usr/bin/open", product_url)
```

Use argv-form process execution for product URLs. Do not interpolate Apple
product URLs into shell strings; URLs can contain query strings and characters
that are meaningful to shells.

Secondary alert options:

- `osascript -e 'display notification ...'`
- `afplay /System/Library/Sounds/Glass.aiff`
- terminal bell
- custom command from config or `REFURB_RADAR_ALERT_COMMAND`

The first implementation should make secondary alerts configurable and run them
non-blockingly after the browser-open attempt. Notification or sound failures
must never prevent opening the product page.

## Error Handling

Expected transient failures:

- Apple fetch timeout.
- Apple serves an unexpected page.
- Embedded JSON missing.
- PDP fetch timeout.
- PDP shape changes.

Behavior:

- Log failures with timestamp and URL.
- Keep polling after transient failures.
- Use exponential backoff only for repeated fetch failures, capped low enough
  that the watcher returns to normal polling quickly.
- Do not open the browser for ambiguous or failed buyability confirmation.

## Test Plan

Unit tests:

- Extract `REFURB_GRID_BOOTSTRAP` from fixture HTML that includes the real
  `window.REFURB_GRID_BOOTSTRAP = {...};` script wrapper.
- Parse all relevant tile fields.
- Match `macmini` and `macstudio`.
- Reject MacBook, iMac, Display, and Mac Pro.
- Accept memory `48gb`, `64gb`, `96gb`, `128gb`.
- Reject memory below 48GB.
- Accept capacity up to `2tb`.
- Reject capacity above 2TB.
- Confirm buyable PDP fixture with `InStock`, enabled Add to Bag, and
  `isBuyable: true`.
- Reject out-of-stock PDP fixture with `OutOfStock`, disabled Add to Bag, and
  `isBuyable: false`.
- Dedupe same SKU while continuously visible.
- Re-alert SKU that stays visible but transitions from unconfirmed or out of
  stock to confirmed buyable.
- Re-alert SKU after disappearance and return.

Manual smoke tests:

1. Run `bin/check-once`.
2. Confirm it prints the current tile count and zero target tiles when no target
   inventory is live.
3. Temporarily point the matcher at a known live iMac fixture to ensure the
   alert path would open a URL.
4. Run `bin/watch` for two polling intervals and confirm jittered sleeps.
5. Install LaunchAgent, verify it is running, then uninstall it.

## Operational Notes

Keep the terminal watcher visible during the first real run. The useful signal
is a browser window opening to a confirmed matching product page.

Do not overinterpret Apple's availability. A refurbished product is not reserved
until checkout and payment authorization complete. This watcher only gets the
user to the buyable product page as fast as practical without automating purchase.
