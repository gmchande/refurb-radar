# Implementation Plan: Multi-Country Apple Refurb Storefronts

Status: planned
Owner: future implementation

## Goal

Make Refurb Radar work across Apple refurbished storefronts beyond Canada while
keeping the current project shape:

- Ruby, stdlib, JSON files, shell wrappers, WEBrick, Minitest.
- No browser automation.
- No add-to-bag, login, checkout, payment, or Apple account automation.
- Canada remains the default behavior.
- Existing `REFURB_RADAR_GRID_URL`, `REFURB_RADAR_BUYABILITY_URL`, and
  `REFURB_RADAR_WATCH_URLS` overrides keep working.

The feature should let a user say: "watch these rules in Canada, the US, and
Japan", then get the same fast local alert behavior when any configured
storefront has a matching buyable refurb product.

## Background

Current behavior is Canada-specific in several places:

- `RefurbRadar::DEFAULT_GRID_URL` points at
  `https://www.apple.com/ca/shop/refurbished/mac`.
- `RefurbRadar::DEFAULT_BUYABILITY_URL` points at
  `https://www.apple.com/ca/shop/buyability-message`.
- `RefurbRadar.short_product_url(part_number)` always builds a Canada product
  URL.
- Candidate, catalog, state, and event identity use bare Apple part numbers.
- Price rules use one `max_price`, implicitly CAD.
- Parser fallback logic is English-heavy for PDP titles.

The core Apple refurb surfaces appear to generalize:

- US: `https://www.apple.com/shop/refurbished/mac`
- Most storefronts: `https://www.apple.com/{storefront}/shop/refurbished/mac`
- Locale storefronts: `be-nl`, `be-fr`, `ch-de`, `ch-fr`
- China mainland: `https://www.apple.com.cn/shop/refurbished/mac`

Representative official pages:

- Canada: `https://www.apple.com/ca/shop/refurbished/mac`
- US: `https://www.apple.com/shop/refurbished/mac`
- UK: `https://www.apple.com/uk/shop/refurbished/mac`
- Germany: `https://www.apple.com/de/shop/refurbished/mac`
- Japan: `https://www.apple.com/jp/shop/refurbished/mac`
- China mainland: `https://www.apple.com.cn/shop/refurbished/mac`

Unsupported or unpublished refurb Mac pages must be treated as source warnings,
not watcher failures.

## Non-Goals

- Do not build a universal Apple Store scraper.
- Do not add exchange-rate conversion.
- Do not compare prices across currencies.
- Do not infer stock from product URLs or HTTP 200.
- Do not change alert semantics except to include storefront context.
- Do not rewrite `Check#run` wholesale.
- Do not add a database or web frontend stack.

## Design Principles

1. Storefront is data, not a mode hidden in URLs.
2. Candidate identity must include storefront.
3. Price constraints are currency-scoped.
4. Parser portability should prefer Apple JSON dimensions over localized title
   text.
5. Canada stays the compatibility path until multi-storefront mode is enabled.
6. Unsupported storefronts should be visible and boring: warn, skip, keep
   running.

## Proposed Config

Add `config/storefronts.json`.

```json
{
  "storefronts": [
    {
      "id": "ca",
      "origin": "https://www.apple.com",
      "path_prefix": "/ca",
      "locale": "en-CA",
      "currency": "CAD",
      "refurb_categories": ["mac"]
    },
    {
      "id": "us",
      "origin": "https://www.apple.com",
      "path_prefix": "",
      "locale": "en-US",
      "currency": "USD",
      "refurb_categories": ["mac"]
    },
    {
      "id": "uk",
      "origin": "https://www.apple.com",
      "path_prefix": "/uk",
      "locale": "en-GB",
      "currency": "GBP",
      "refurb_categories": ["mac"]
    },
    {
      "id": "de",
      "origin": "https://www.apple.com",
      "path_prefix": "/de",
      "locale": "de-DE",
      "currency": "EUR",
      "refurb_categories": ["mac"]
    },
    {
      "id": "jp",
      "origin": "https://www.apple.com",
      "path_prefix": "/jp",
      "locale": "ja-JP",
      "currency": "JPY",
      "refurb_categories": ["mac"]
    },
    {
      "id": "cn",
      "origin": "https://www.apple.com.cn",
      "path_prefix": "",
      "locale": "zh-CN",
      "currency": "CNY",
      "refurb_categories": ["mac"]
    }
  ]
}
```

Extend `config/targets.json` rules without breaking existing rules:

```json
{
  "rules": [
    {
      "models": ["macstudio"],
      "storefronts": ["ca", "us", "jp"],
      "min_memory_gb": 64,
      "min_cpu_cores": 14,
      "max_capacity_gb": 4096,
      "max_prices": {
        "CAD": 4200,
        "USD": 3200,
        "JPY": 480000
      }
    }
  ]
}
```

Compatibility:

- Missing `storefronts` means `["ca"]`.
- Existing `max_price` means CAD-only in Canada mode.
- New `max_prices` wins when present.

Environment:

- `REFURB_RADAR_STOREFRONT=ca` for one storefront.
- `REFURB_RADAR_STOREFRONTS=ca,us,jp` for multiple storefronts.
- Existing URL overrides keep highest precedence for single-storefront dry runs.
- `REFURB_RADAR_STOREFRONTS_PATH` may point at an alternate storefront config.

## Data Model

Add to `RefurbRadar::Candidate`:

- `storefront`
- `currency`

Add a helper:

```ruby
def identity
  "#{storefront}:#{part_number.upcase}"
end
```

Use identity anywhere a candidate is keyed:

- `StateStore#alertable_candidates`
- `StateStore#mark_alerted`
- `StateStore#record_alert_attempt`
- `CatalogRefresh#merge_catalog`
- `Config.watch_candidates`
- event payloads and status-page read models

Keep `part_number` as its own field for display and Apple buyability calls.

Catalog product records should include:

```json
{
  "identity": "ca:G1JVELL/A",
  "storefront": "ca",
  "currency": "CAD",
  "part_number": "G1JVELL/A",
  "url": "https://www.apple.com/ca/shop/product/G1JVELL/A"
}
```

State migration should be lazy:

- Existing records without `storefront` are Canada records.
- Existing keys like `G1JVELL/A` should be read as `ca:G1JVELL/A`.
- On next save, write the normalized identity keys.

## Storefront Model

Add `lib/refurb_radar/storefront.rb`.

Responsibilities:

- Load storefront definitions from JSON.
- Select active storefronts from env and targets.
- Build URLs for refurb category pages.
- Build buyability endpoint URLs.
- Build short product URLs.
- Carry currency metadata.

Suggested public surface:

```ruby
storefront = RefurbRadar::Storefront.find("ca")
storefront.grid_url("mac")
storefront.buyability_url
storefront.product_url("G1JVELL/A")
```

Rules:

- `origin` has no trailing slash.
- `path_prefix` is either `""` or starts with `/`.
- `grid_url("mac")` returns
  `"#{origin}#{path_prefix}/shop/refurbished/mac"`.
- `buyability_url` returns
  `"#{origin}#{path_prefix}/shop/buyability-message"`.
- China is represented by `origin: "https://www.apple.com.cn"` and empty
  `path_prefix`.

## Implementation Phases

### Phase 1: Storefront URL Layer

Purpose: introduce storefronts without changing multi-store behavior yet.

Files:

- `config/storefronts.json`
- `lib/refurb_radar/storefront.rb`
- `lib/refurb_radar.rb`
- `test/refurb_radar_test.rb`

Work:

1. Add `Storefront` and `Storefronts` classes or a small module.
2. Add tests for URL building:
   - `ca` grid and buyability URLs.
   - `us` empty path prefix.
   - `be-fr` or `ch-de` locale path prefix.
   - `cn` `apple.com.cn` origin.
3. Change `DEFAULT_GRID_URL` and `DEFAULT_BUYABILITY_URL` to derive from the
   default Canada storefront, while preserving current string values.
4. Change `short_product_url(part_number)` to delegate to Canada storefront.

Acceptance:

- Existing tests still pass.
- No command behavior changes without new env vars.

### Phase 2: Candidate Storefront Metadata

Purpose: carry storefront and currency through parsed candidates.

Files:

- `lib/refurb_radar.rb`
- `lib/refurb_radar/parser.rb`
- `lib/refurb_radar/catalog.rb`
- `lib/refurb_radar/config.rb`
- fixtures and tests

Work:

1. Add `storefront` and `currency` fields to `Candidate`.
2. Add `Candidate#identity` or equivalent helper.
3. Update grid parsing to receive storefront metadata, not just `base_url`.
4. Update PDP/catalog parsing to receive storefront metadata.
5. Default missing storefront/currency to Canada/CAD for compatibility.
6. Write `storefront`, `currency`, and `identity` into catalog records.
7. Read old catalog rows without those fields as Canada rows.

Acceptance:

- Catalog rows for Canada include `identity: "ca:..."`.
- Existing seed catalog still loads.
- Existing tests pass after fixture updates.

### Phase 3: State And Event Identity

Purpose: avoid collisions across countries and keep alert dedupe correct.

Files:

- `lib/refurb_radar/state_store.rb`
- `lib/refurb_radar/event_log.rb` call sites
- `lib/refurb_radar/inventory_snapshot.rb`
- `lib/refurb_radar/status_page.rb`
- tests

Work:

1. Replace bare `candidate.part_number` map keys with `candidate.identity`.
2. Keep display text as bare part number plus storefront badge.
3. Lazy-migrate old state keys:
   - if key includes `:`, keep it.
   - otherwise normalize to `ca:#{key}`.
4. Event payloads should include both `identity` and `part_number`.
5. Status page should show storefront and currency on listings and history rows.

Acceptance:

- `ca:G1JVELL/A` and `us:G1JVELL/A` can coexist.
- Old `state/seen.json` remains readable.
- Alerts are deduped per storefront, not globally by part number.

### Phase 4: Multi-Storefront Buyability

Purpose: verify buyability per storefront using the right endpoint.

Files:

- `lib/refurb_radar/buyability.rb`
- `lib/refurb_radar.rb`
- `bin/check-once`
- `bin/watch`
- tests

Work:

1. Keep `BuyabilityEndpoint` simple and endpoint-specific.
2. Add routing in `Check`:
   - group eligible candidates by storefront.
   - call the storefront's buyability endpoint for each group.
   - merge flags back by candidate identity.
3. Ensure part numbers passed to Apple stay bare, not `ca:PART`.
4. Include storefront in warning messages.
5. Add tests for two storefronts with the same part number and different flags.

Acceptance:

- A US buyability failure does not hide Canada results.
- Buyability metadata is recorded per storefront.
- Existing Canada-only behavior is unchanged.

### Phase 5: Rules And Currency-Scoped Prices

Purpose: let users watch different storefronts without invalid price comparisons.

Files:

- `lib/refurb_radar/matcher.rb`
- `lib/refurb_radar/targets_store.rb`
- `bin/serve-status`
- `lib/refurb_radar/status_page.rb`
- `config/targets.json`
- tests

Work:

1. Extend `Matcher::Rule` with `storefronts` and `max_prices`.
2. Normalize `storefronts` like models.
3. `shortfalls` adds `:storefront` when a rule does not cover the candidate's
   storefront.
4. Existing `max_price` applies only when no `max_prices` is present.
5. `max_prices` looks up by candidate currency.
6. Do not compare across currencies.
7. Status page can initially show storefront and currency read-only; editing UI
   for storefronts can be a follow-up if needed.

Acceptance:

- Canada-only rules still behave as before.
- A USD candidate is evaluated against USD price caps only.
- Unknown currency fails closed for price-constrained rules.

### Phase 6: Source Discovery And Refresh

Purpose: refresh catalogs across active storefronts without rewriting the watcher.

Files:

- `lib/refurb_radar/catalog.rb`
- `lib/refurb_radar/config.rb`
- `bin/refresh-catalog`
- `bin/watch`
- tests

Work:

1. Add a storefront-aware refresh runner that loops active storefronts.
2. Each storefront gets its own grid URL and seed/direct PDP URLs.
3. Store seed URLs with storefront metadata. Prefer a new JSON source file over
   overloading `config/watch_urls.txt`.
4. Keep `config/watch_urls.txt` as Canada-compatible legacy input.
5. Record unsupported or unpublished storefront/category as a warning, not a
   process failure.

Possible source config:

```json
{
  "sources": [
    { "storefront": "ca", "category": "mac" },
    { "storefront": "us", "category": "mac" },
    {
      "storefront": "jp",
      "url": "https://www.apple.com/jp/shop/product/example"
    }
  ]
}
```

Acceptance:

- `bin/refresh-catalog` can refresh Canada alone by default.
- `REFURB_RADAR_STOREFRONTS=ca,us bin/refresh-catalog` writes both storefronts
  into one catalog without collisions.
- Unsupported storefronts produce warnings and do not block other storefronts.

### Phase 7: Local UX And Docs

Purpose: make the multi-country feature understandable without turning the app
into a SaaS dashboard.

Files:

- `README.md`
- `docs/environment.md`
- `docs/roadmap.md`
- `docs/social-post.md` if announcement copy changes
- status page files if needed

Work:

1. Document `REFURB_RADAR_STOREFRONT` and `REFURB_RADAR_STOREFRONTS`.
2. Document storefront config and currency-scoped prices.
3. Update examples to keep Canada simple.
4. Add a note that local browser opening works best for the user's own country,
   while cross-country alerts may still require country-specific checkout
   constraints.
5. Keep browser-open as the primary documented alert loop. Twilio SMS/calls are
   optional, off by default, and must not require or include hardcoded phone
   numbers in code, config, fixtures, or docs.
6. Status page should show a storefront badge in target cards and listings.

Acceptance:

- A Canada-only user does not need to learn multi-country config.
- A power user can configure `ca,us,jp` from docs alone.
- A local user can run the main browser-open loop with no Twilio credentials.

## Test Plan

### Unit Tests

- Storefront URL builder:
  - Canada: `https://www.apple.com/ca/shop/refurbished/mac`
  - US: `https://www.apple.com/shop/refurbished/mac`
  - Switzerland French: `https://www.apple.com/ch-fr/shop/refurbished/mac`
  - China: `https://www.apple.com.cn/shop/refurbished/mac`
- Buyability URL builder:
  - same origin and path prefix rules as grid URLs
  - preserves existing query generation
- Candidate identity:
  - default Canada identity for old candidates
  - `ca:PART` and `us:PART` do not collide
- Catalog migration:
  - old rows without storefront load as Canada
  - new rows write identity, storefront, and currency
- State migration:
  - old `currently_seen` keys normalize to `ca:PART`
  - alert dedupe stays per identity
- Matcher:
  - missing storefront rule defaults to Canada
  - storefront mismatch produces a shortfall
  - `max_prices` checks only candidate currency
  - unknown currency fails closed when price constrained
- Parser:
  - grid dimensions are preferred over localized title fallback
  - localized fixtures still produce model/memory/capacity where JSON exposes
    those fields

### Fixture Coverage

Capture static fixtures for:

- Canada grid
- US grid
- Germany or France grid
- Japan grid
- China grid
- one unsupported storefront response
- buyability JSON for two storefronts with overlapping part numbers

Do not make tests hit Apple live pages.

### Smoke Checks

After unit tests pass:

```sh
REFURB_RADAR_OPEN=0 REFURB_RADAR_STOREFRONT=ca bin/check-once
REFURB_RADAR_OPEN=0 REFURB_RADAR_STOREFRONT=us bin/check-once
REFURB_RADAR_OPEN=0 REFURB_RADAR_STOREFRONT=jp bin/check-once
REFURB_RADAR_OPEN=0 REFURB_RADAR_STOREFRONTS=ca,us bin/check-once
```

Only after dry runs are stable should browser-open alerts be enabled.

## Migration Notes

Backward compatibility is important because current users may already have
state, catalog, and target files.

Read compatibility:

- Missing candidate storefront means `ca`.
- Missing currency means `CAD`.
- Missing product identity means `"ca:#{part_number}"`.
- Existing `max_price` remains valid for Canada rules.
- Existing `config/watch_urls.txt` remains a Canada seed list.

Write behavior after migration:

- Write normalized identity keys.
- Write storefront and currency into catalog/state/event records.
- Prefer preserving old fields rather than deleting them.

## Risks And Mitigations

### Localized Product Text

Risk: PDP title parsing is English-oriented.

Mitigation: use grid and variation JSON dimensions first. Treat PDP text parsing
as fallback only. Add localized fixtures before turning on a storefront by
default.

### Currency Confusion

Risk: `max_price` in CAD accidentally filters USD or JPY.

Mitigation: scoped `max_prices`; no exchange rates; missing currency fails
closed when a price cap is present.

### Part Number Collisions

Risk: the same bare part number suffix can appear in multiple countries or
future catalogs.

Mitigation: all state/catalog/event identity keys include storefront.

### Unsupported Storefronts

Risk: a country exists as an Apple store but has no refurb Mac page.

Mitigation: source warnings and per-storefront failures; never abort the whole
watcher because one storefront is unpublished.

### Alert Noise

Risk: multi-country polling creates noisy or unactionable alerts.

Mitigation: default remains Canada; multi-storefront rules are opt-in; status
page shows storefront clearly; checkout remains manual.

## Suggested Issue Breakdown

1. Add storefront config and URL builder.
2. Add candidate storefront/currency fields and catalog write/read support.
3. Migrate state/event identity to storefront-qualified keys.
4. Route buyability checks by storefront.
5. Add storefront and currency-aware matching rules.
6. Make catalog refresh storefront-aware.
7. Update status page and docs for multi-country mode.
8. Add non-Canada fixtures and smoke-test instructions.

Each issue should keep Canada-only behavior green before expanding the next
surface.
