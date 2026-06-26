# Roadmap

Refurb Radar is useful because it stays narrow. The roadmap should preserve that
shape: faster confidence, clearer controls, fewer false alerts, no purchasing
automation.

## Near-Term

- Polish the public README as real users try the tool.
- Add one or two lightweight screenshots or GIFs if they explain setup better
  than text.
- Split the large status-page file only when extraction makes everyday changes
  easier to reason about.
- Split the large test file by behavior area if that helps contributors find the
  right tests faster.

## Watch Target Discovery

The watcher already handles configured targets and direct refurbished product
URLs. Prospective discovery for categories that Apple does not yet expose as a
stable refurbished grid is planned, not complete.

Good future work here would:

- keep target discovery separate from buyability claims
- clearly label "not yet seen" versus "seen but not buyable"
- reuse direct SKU and catalog evidence where Apple exposes it
- avoid speculative scraping that creates noisy alerts

## Explicitly Out Of Scope

- Add-to-bag automation.
- Checkout, payment, login, or Apple account automation.
- Browser automation for the core watcher.
- A frontend build chain.
- A database before JSON files become a real bottleneck.
