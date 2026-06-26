# Public Release Checklist

This repo is ready to publish only after both the working tree and the public git
history are safe.

## Recommended History Strategy

For this small experiment, publish from a separate clean local repository with a
fresh initial commit.

Reason: earlier private operational history may contain real infrastructure
identifiers. Cleaning current files is necessary, but it does not remove old
values from existing git history.

Do not add a new remote to this private repo and push `main`.

Recommended local shape:

```text
path/to/private/refurb-radar
path/to/public/refurb-radar
```

The first path is the private working repo. The second path is the public export
repo with its own `.git` directory and no inherited history.

## Fresh Publish Steps

From the private working repo:

```sh
export PRIVATE_REPO=/path/to/private/refurb-radar
export PUBLIC_REPO=/path/to/public/refurb-radar

rm -rf "$PUBLIC_REPO"
mkdir -p "$PUBLIC_REPO"

rsync -a --delete \
  --exclude='.git/' \
  --exclude='.claude/' \
  --exclude='.ruby-lsp/' \
  --exclude='.playwright-mcp/' \
  --exclude='.scratch/' \
  --exclude='.tmp' \
  --exclude='.env' \
  --exclude='.kamal/secrets' \
  --exclude='config/deploy.production.yml' \
  --exclude='log/*.log' \
  --exclude='state/*.json' \
  --exclude='state/*.jsonl' \
  --exclude='state/*.lock' \
  --exclude='/apple-refurb-status-*.png' \
  "$PRIVATE_REPO/" "$PUBLIC_REPO/"

cd "$PUBLIC_REPO"
git init
git add .
git commit -m "Initial public release"
git branch -M main
git remote add origin git@github.com:gmchande/refurb-radar.git
git push -u origin main
```

Run the checks below before the commit and before the push.

For a real release, also keep a local, uncommitted pattern file containing any
private values known to have appeared in old history, then scan the export:

```sh
mkdir -p "$PRIVATE_REPO/.scratch"
$EDITOR "$PRIVATE_REPO/.scratch/private-release-patterns.txt"
rg -n --fixed-strings --file "$PRIVATE_REPO/.scratch/private-release-patterns.txt" "$PUBLIC_REPO"
```

## If Preserving History

Only preserve existing history after the owner explicitly approves that choice.
Before doing so, rotate or replace any infrastructure values that appeared in
old commits.

## Current-Tree Checks

Run these before a public push:

```sh
git status --short --ignored
PUBLIC_SCAN_RE='YOUR_USERNAME|/Users/|requires [A-Z][a-z]+|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
rg -n --glob '!docs/release.md' "$PUBLIC_SCAN_RE" . 2>/dev/null
rg -n --glob '!docs/release.md' 'AC[a-fA-F0-9]{32}|[a-fA-F0-9]{64}|\+1[0-9]{10}' . 2>/dev/null
bundle exec ruby test/refurb_radar_test.rb
```

The scan may flag public Apple URL parameters or fake test phone numbers. Review
each hit before publishing.
