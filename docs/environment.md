# Environment Reference

Refurb Radar reads environment variables directly from the process. It does not
autoload `.env` files.

Use exports in your shell, LaunchAgent plist, Kamal config, or another process
manager:

```sh
export REFURB_RADAR_OPEN=0
export REFURB_RADAR_BROWSER_ALERT=1
export REFURB_RADAR_TARGETS=config/targets.json
```

## Watcher State

```sh
export REFURB_RADAR_STATE=state/seen.json
export REFURB_RADAR_CATALOG=state/catalog.json
export REFURB_RADAR_EVENTS=state/events.jsonl
export REFURB_RADAR_CONTROLS=state/controls.json
```

## Polling And Catalog

```sh
export REFURB_RADAR_CATALOG_REFRESH_INTERVAL=1800
export REFURB_RADAR_GRID_URL=https://www.apple.com/ca/shop/refurbished/mac
export REFURB_RADAR_BUYABILITY_URL=https://www.apple.com/ca/shop/buyability-message
```

`bin/watch` uses jittered sleeps. Avoid fixed synchronized polling intervals.

## Alerts

```sh
export REFURB_RADAR_OPEN=1
export REFURB_RADAR_BROWSER_ALERT=1
export REFURB_RADAR_ALERT_COMMAND='afplay /System/Library/Sounds/Glass.aiff'
export REFURB_RADAR_REMINDER_INTERVAL=300
```

Twilio:

```sh
export TWILIO_ACCOUNT_SID=...
export TWILIO_AUTH_TOKEN=...
export TWILIO_FROM_NUMBER=...
export REFURB_RADAR_ALERT_TO=...
export REFURB_RADAR_TWILIO_SMS=1
export REFURB_RADAR_TWILIO_CALL=0
```

## Status Page

```sh
export HOST=0.0.0.0
export PORT=8127
export REFURB_RADAR_STATUS_BASE_PATH=/refurb-radar
export REFURB_RADAR_STATUS_PUBLIC_URL=https://example.com/refurb-radar/
```

Optional Cloudflare Access:

```sh
export CLOUDFLARE_ACCESS_TEAM_DOMAIN=your-team.cloudflareaccess.com
export CLOUDFLARE_ACCESS_AUD=your-cloudflare-access-audience
```
