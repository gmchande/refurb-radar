# Security Policy

Please report security issues privately to the project owner before opening a
public issue.

If you publish a fork, rotate any credentials or infrastructure identifiers you
accidentally commit. Do not rely on deleting a current file if the value remains
in git history.

## Boundaries

Refurb Radar must stay a watcher:

- no Apple account automation
- no login automation
- no add-to-bag automation
- no checkout or payment automation
- no claims of stock without direct buyability evidence

## Secrets

Do not commit:

- `.kamal/secrets`
- `.env`
- private deploy configs
- Twilio tokens
- phone numbers
- Cloudflare Access credentials
- real SSH key paths or server-specific values you do not intend to publish

Use `.kamal/secrets.example`, `.env.example`, and placeholder values in tracked
docs and config.

## Status Page Exposure

The status page is a control panel. It includes state-changing routes for watch
rules, alert-channel pauses, and test alerts. Test alerts can use real Twilio
SMS or call channels if those environment variables are configured.

Do not expose the status page publicly without Cloudflare Access, reverse-proxy
authentication, a VPN, or an equivalent access-control layer. When Cloudflare
Access variables are unset, the page accepts local requests without
authentication.
