# Contributing

Refurb Radar is intentionally small: Ruby, standard library, WEBrick, JSON
files, shell wrappers, Minitest, and launchd/Kamal deployment glue.

## Ground Rules

- Keep checkout manual. Do not add add-to-bag, login, payment, Apple account, or
  checkout automation.
- Do not claim stock from URLs or HTTP 200 responses alone. Actionable alerts
  require direct buyability evidence.
- Do not add Node, Playwright, Rails, Roda, SQLite, or a frontend build chain
  unless the project has a real, documented need.
- Prefer small changes that keep the watcher easy to inspect and run.
- Keep local state in small JSON/JSONL files unless durable querying becomes a
  proven requirement.

## Development

```sh
bundle install
bundle exec ruby test/refurb_radar_test.rb
```

Useful smoke checks:

```sh
REFURB_RADAR_OPEN=0 bin/check-once
REFURB_RADAR_OPEN_COMMAND=/usr/bin/true bin/send-test-alert
bundle exec ruby bin/serve-status
```

## Ruby Style

Follow the style in `AGENTS.md`: domain-visible POROs, top-down method order,
expanded conditionals when they improve readability, and comments only for
constraints the code cannot show.

## Pull Requests

Please include:

- what changed
- why it is useful
- what command verified it
- whether it touches alerting, buyability semantics, or polling behavior

If a change affects alert eligibility, add or update focused tests.
