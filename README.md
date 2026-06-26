# Refurb Radar

Catch the Apple Canada refurb machines you actually want, before they vanish.

Refurb Radar is a small Ruby watcher for Apple Canada refurbished inventory. It
polls the refurb grid and known product pages, filters listings through your
target rules, confirms direct buyability, and alerts you so checkout stays
manual.

It never adds to bag, logs in, checks out, pays, or automates an Apple account.

## Why It Exists

Great Apple refurb configurations show up quietly and disappear fast. Generic
"Macs are in stock" alerts are noisy; Refurb Radar watches for exact machines:
model, screen size, chip family, RAM, CPU cores, SSD size, and price cap.

The useful moment is narrow: detect a matching machine, verify Apple says it is
buyable, and get the product page in front of a human quickly.

## What It Does

- Polls Apple Canada's refurbished Mac grid and generated direct SKU URLs.
- Builds a local catalog of known refurbished product variants.
- Filters candidates through plain JSON target rules.
- Confirms actionability from direct buyability evidence.
- Opens the matching Apple product page locally; optional Twilio SMS/call alerts
  can be enabled separately.
- Serves a small WEBrick status and control page for the current watch rules.
- Runs locally with launchd or on a small server with Kamal.

## What Counts As Buyable

Refurb Radar does not treat a product URL or HTTP 200 as stock.

A product is actionable only when Apple exposes one of these direct signals:

- `schema.org/InStock`
- an enabled Add to Bag control
- `isBuyable: true` from Apple's buyability message endpoint

Out-of-stock signals such as `schema.org/OutOfStock`, disabled Add to Bag, or
`isBuyable: false` are treated as not actionable.

## Quickstart

Requirements:

- macOS
- Ruby matching `.ruby-version`
- Bundler

```sh
bundle install
bin/refresh-catalog
REFURB_RADAR_OPEN=0 bin/check-once
bundle exec ruby bin/serve-status
```

Then open:

```text
http://127.0.0.1:8127/refurb-radar/
```

Run the watcher:

```sh
bin/watch
```

Run tests:

```sh
bundle exec ruby test/refurb_radar_test.rb
```

## Choosing What To Watch

Watch rules live in `config/targets.json` by default. Every constraint is
optional; unknown values fail closed for constraints that need them.

```json
{
  "rules": [
    {
      "models": ["macmini", "macstudio"],
      "min_memory_gb": 64,
      "min_cpu_cores": 14,
      "max_capacity_gb": 4096,
      "max_price": 3500
    },
    {
      "models": ["macbookpro"],
      "screen_size_inches": 14,
      "chip_family": "m5",
      "min_memory_gb": 24,
      "max_capacity_gb": 512
    }
  ]
}
```

Supported fields include:

- `models`: Apple product family keys such as `macmini`, `macstudio`,
  `macbookair`, `macbookpro`, or `visionpro`.
- `screen_size_inches`: useful for MacBook rules.
- `chip_family`: examples include `m4`, `m4pro`, `m4max`, and future families
  as they appear in the catalog.
- `min_memory_gb` and `max_memory_gb`.
- `min_cpu_cores`.
- `max_capacity_gb`.
- `max_price`.

The status page can edit the same rules. `bin/check-once` and `bin/watch`
re-read the targets file each pass, so changes are live within one sweep.

## Status Page

The status page is a small server-rendered WEBrick app, not a dashboard stack.
It is also a control panel: it can edit watch rules, pause alert channels, and
send test alerts.

Do not expose it to the public internet without Cloudflare Access, a reverse
proxy with authentication, or an equivalent access-control layer. If Cloudflare
Access variables are unset, the page is open by design for local use.

It shows:

- what rules are currently being watched
- which catalog entries match or narrowly miss each rule
- whether a candidate is listed, directly checked, buyable, or not buyable
- current alert-channel pause state
- recent scan and alert evidence from local JSON/JSONL files

Start it locally:

```sh
bundle exec ruby bin/serve-status
```

Useful deployment variables:

```sh
HOST=0.0.0.0
PORT=8127
REFURB_RADAR_STATUS_BASE_PATH=/refurb-radar
REFURB_RADAR_STATUS_PUBLIC_URL=https://example.com/refurb-radar/
```

If you put it behind Cloudflare Access, set:

```sh
CLOUDFLARE_ACCESS_TEAM_DOMAIN=your-team.cloudflareaccess.com
CLOUDFLARE_ACCESS_AUD=your-cloudflare-access-audience
```

## Alerts

Browser open is enabled by default:

```sh
REFURB_RADAR_OPEN=1
REFURB_RADAR_BROWSER_ALERT=1
```

For dry runs:

```sh
REFURB_RADAR_OPEN=0 bin/check-once
REFURB_RADAR_OPEN_COMMAND=/usr/bin/true bin/send-test-alert
```

Optional Twilio alerts:

Twilio is not required for the main local workflow. Leave these unset unless
you explicitly want SMS or phone-call alerts in addition to browser-open.

```sh
export TWILIO_ACCOUNT_SID=...
export TWILIO_AUTH_TOKEN=...
export TWILIO_FROM_NUMBER=...
export REFURB_RADAR_ALERT_TO=...
export REFURB_RADAR_TWILIO_SMS=1
export REFURB_RADAR_TWILIO_CALL=0

bin/send-test-alert
```

The app reads environment variables directly. See `docs/environment.md` and
`.env.example` for a fuller manual reference.

## Commands

```sh
bin/refresh-catalog
bin/check-once
bin/watch
bundle exec ruby bin/serve-status
bin/send-test-alert
bin/install-launch-agent
bin/uninstall-launch-agent
bundle exec ruby test/refurb_radar_test.rb
```

`bin/watch` sleeps with jitter instead of a fixed interval. Local state is kept
small and boring:

- `state/seen.json`: alert and reminder dedupe
- `state/catalog.json`: generated direct SKU catalog
- `state/events.jsonl`: append-only scan and alert evidence
- `state/controls.json`: paused alert-channel state

## LaunchAgent

Install the local macOS watcher:

```sh
bin/install-launch-agent
```

Remove it:

```sh
bin/uninstall-launch-agent
```

Logs go to `log/watcher.log` and `log/watcher.err.log`.

## Server Deployment

The tracked `config/deploy.yml` is a generic Kamal example. Fill in your own
host, Docker registry, domain, SSH key, and Cloudflare Access or equivalent
status-page protection.

```sh
cp .kamal/secrets.example .kamal/secrets
# fill in KAMAL_REGISTRY_PASSWORD and any alert secrets
kamal deploy
kamal app exec --reuse --roles worker "ruby bin/send-test-alert"
kamal app logs -f
```

For private deployments, keep real infrastructure in an ignored file:

```sh
kamal deploy -c config/deploy.production.yml
```

Kamal's `-c` flag is supported as `--config-file`.

Production state should be mounted outside the container, for example:

```text
/srv/refurb-radar/state:/app/state
/srv/refurb-radar/log:/app/log
```

That keeps alert dedupe, generated catalog data, and rule edits across deploys.

## Safety

This project is deliberately a watcher, not a purchasing bot.

- No add-to-bag automation.
- No checkout automation.
- No login or Apple account automation.
- No payment automation.
- No claim of stock without direct buyability evidence.

You are responsible for how often you poll and for respecting the sites and
services you connect to.

## Roadmap

Planned or intentionally small-scope work:

- Better public docs around prospective watch targets.
- Optional support for additional Apple refurbished categories as Apple exposes
  stable pages or direct refurbished product URLs.
- Mechanical extraction of the large status page file if it starts slowing down
  everyday changes.
- Focused test-file splitting by domain, without changing behavior.

Not planned by default:

- Browser automation.
- Checkout automation.
- A frontend build chain.
- A database.
- A Rails or Roda app.

See `docs/roadmap.md` for more detail.

## Contributing

See `CONTRIBUTING.md`.

## License

MIT. See `LICENSE`.
