# Refurb Radar - Agent Guidance

## Project shape

This is a small local macOS watcher for Apple Canada refurbished Mac inventory.
It polls Apple refurbished Mac pages, filters for target Mac mini / Mac Studio
configurations, confirms buyability on the product detail page, and opens the
matching product page in the user's browser.

## Stack

Use Ruby, the Ruby standard library, shell wrappers, JSON files, and macOS
LaunchAgent plist files.

Do not add Node, Playwright, browser automation, Rails, Roda, SQLite, or a
frontend build chain unless the watcher proves it needs them. The verified Apple
page already exposes enough server-rendered HTML and JSON for a lightweight
poller, and the requested action is only to open the product page for human
checkout.

## Commands

Planned command shape:

- `bin/check-once` - fetch once, parse, print current status, and exit.
- `bin/watch` - poll forever with randomized sleep around 30 seconds.
- `bin/refresh-catalog` - refresh generated direct SKU URLs from grid and seed PDPs.
- `bin/install-launch-agent` - install and load the per-user LaunchAgent.
- `bin/uninstall-launch-agent` - unload and remove the LaunchAgent.
- `ruby test/refurb_radar_test.rb` - run focused unit tests once code exists.

## Domain constraints

- Do not claim stock from a product URL or HTTP 200 alone.
- Treat a product as actionable only after a direct buyability signal:
  `schema.org/InStock`, enabled Add to Bag button, or `isBuyable: true`.
- Treat `schema.org/OutOfStock`, disabled Add to Bag, or `isBuyable: false` as
  not actionable.
- Do not automate checkout, add-to-bag, payment, login, or Apple account actions.
  The script may open a browser page and alert the user; purchasing remains
  manual.
- Avoid exact fixed polling intervals. Use jitter around 30 seconds.
- Keep state local and small. JSON is enough unless durable querying becomes a
  real requirement.

## Taste

Prefer a boring command-line tool with clear logs over a dashboard. The useful
moment is detecting a matching machine and opening the page fast.

## Ruby taste

When writing Ruby, follow the spirit of Matz and DHH: optimize for programmer
happiness, make the domain visible, favour harmony over rigid purity, and use
expressive Ruby only when it clarifies the work.

### Ruby style specifics

Follow 37signals house style (their STYLE.md, Campfire, Writebook):

- Prefer expanded `if`/`else` over guard clauses. Two cases permit a guard
  clause: a single early `return` as the very first line of a method, or a
  `return if ...` atop a method whose main body runs several lines. Never
  stack or nest guard clauses. Simple one-expression ternaries are fine
  (`closed? ? reopen : close`); expand anything longer.
- Order methods by invocation order, top-down: class methods, then public
  (`initialize` first), then private. A reader should be able to read the
  file like a narrative.
- Indent private methods one level under the `private` keyword, with no
  blank line directly after it.
- Use `!` only when a non-bang counterpart exists, never just to mark a
  method as destructive.
- Name domain operations as intention-revealing verbs on the model
  (`watcher.check`, `catalog.refresh`, `listing.buyable?`), and predicates
  with `?`. Avoid generic `process`/`handle`/`manage` names.
- Reach for the expressive core: `tap`, `then`, `Array()`, `&:method`;
  default to keyword arguments once a second parameter is not self-evident
  at the call site.
- POROs: `attr_reader` for collaborators, keyword-argument `initialize`,
  small public surface, private methods below in invocation order.
- Comment why, not what — and only for constraints the code cannot show
  (workarounds, perf, odd domain rules). No section-header comments.
- Don't write defensive ceremony: no broad rescues, no nil-checking every
  argument, no speculative options hashes. Return booleans or `nil` for
  expected-miss lookups; raise only for programmer errors.
