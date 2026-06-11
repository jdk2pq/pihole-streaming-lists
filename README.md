# Pi-hole Streaming Lists

All domain research and regex patterns are sourced from the excellent gist by **[ozankiratli](https://github.com/ozankiratli)**:
> https://gist.github.com/ozankiratli/801ba17705e7f2a904d2e443af5a64f8

This repo reformats that work into plain-text files ready for Pi-hole, and adds install/update scripts. No content has been changed — only organized into files and annotated with inline comments.

---

Pi-hole allowlists and denylists for blocking ads on streaming platforms while keeping the services functional.

## Quick install

Run this on your Pi-hole device:

```bash
# All platforms (default)
curl -sSL https://raw.githubusercontent.com/jdk2pq/pihole-streaming-lists/main/install.sh | sudo bash

# Specific platforms only
curl -sSL https://raw.githubusercontent.com/jdk2pq/pihole-streaming-lists/main/install.sh | sudo bash -s -- roku peacock
```

Available platforms: `roku` `peacock` `paramount-plus` `disney-plus`

**Prefer to read the script before running it?**

```bash
curl -sSL https://raw.githubusercontent.com/jdk2pq/pihole-streaming-lists/main/install.sh -o install.sh
less install.sh        # read it
sudo bash install.sh   # run it when satisfied
```

**Want to preview what will be added without making any changes?**

```bash
sudo bash install.sh --dry-run
```

**What the scripts actually do:**
- Clone this repo to `/opt/pihole-streaming-lists`
- Back up `/etc/pihole/gravity.db` before touching it (keeps the 5 most recent backups)
- Insert domains and regex patterns with `INSERT OR IGNORE` — existing entries are never modified or removed
- Verify the git remote is `github.com/jdk2pq/pihole-streaming-lists` before pulling any updates
- Reload Pi-hole DNS only if something was actually added

Nothing outside of `/opt/pihole-streaming-lists` and `/etc/pihole/gravity.db` is created or modified.

**To update later** (pull new entries and re-apply):

```bash
# All platforms
sudo /opt/pihole-streaming-lists/update.sh

# Specific platforms
sudo /opt/pihole-streaming-lists/update.sh roku peacock
```

**To auto-update weekly**, add this to root's crontab (`sudo crontab -e`):

```
0 3 * * 0   root   /opt/pihole-streaming-lists/update.sh >> /var/log/pihole-streaming-lists.log 2>&1
```

---

All domain research and regex patterns are sourced from the excellent gist by **[ozankiratli](https://github.com/ozankiratli)**:
> https://gist.github.com/ozankiratli/801ba17705e7f2a904d2e443af5a64f8

This repo reformats that work into plain-text files that can be dropped directly into Pi-hole. No content has been changed — only organized into files and annotated with inline comments.

---

## Platforms

| Platform | Allowlist | Allowlist (regex) | Denylist | Denylist (regex) |
|---|---|---|---|---|
| [Roku](#roku) | ✅ | — | ✅ | ✅ |
| [Peacock](#peacock) | ✅ | ✅ | ✅ | ✅ |
| [Paramount+](#paramount) | ✅ | ✅ | ✅ | — |
| [Disney+](#disney) | — | — | — | ✅ |

---

## How to add lists to Pi-hole

### Regex patterns — bulk import script

Cloning the repo onto your Pi-hole machine and running the import script is the fastest way to get all regex entries loaded:

```bash
git clone https://github.com/jdk2pq/pihole-streaming-lists.git
cd pihole-streaming-lists

# Preview what would be added (no changes made)
./import-regex.sh --dry-run

# Import everything
sudo ./import-regex.sh

# Import only one platform
sudo ./import-regex.sh roku
sudo ./import-regex.sh peacock
sudo ./import-regex.sh paramount-plus
sudo ./import-regex.sh disney-plus
```

The script writes directly to Pi-hole's SQLite database (`/etc/pihole/gravity.db`), skips duplicates, and runs `pihole restartdns reload-lists` automatically when done. If your database is in a non-standard location, set `GRAVITY_DB=/path/to/gravity.db` before running.

### Exact domains (allowlist / denylist)

1. Go to the Pi-hole admin panel → **Domains** → select the **Allowlist** or **Denylist** tab.
2. Paste individual domains, or bulk-import via CLI:

```bash
# Allowlist
grep -v '^#\|^$' roku/allowlist.txt | xargs -I{} pihole --white-list {}

# Denylist
grep -v '^#\|^$' roku/denylist.txt | xargs -I{} pihole --black-list {}
```

---

## Roku

**Files:**
- [`roku/allowlist.txt`](roku/allowlist.txt) — Core Roku domains + The Roku Channel domains
- [`roku/denylist.txt`](roku/denylist.txt) — Exact ad/tracking domains
- [`roku/denylist-regex.txt`](roku/denylist-regex.txt) — Regex patterns for ads and telemetry

**Notes:**
- Section 1 of the allowlist (core domains) should always be kept. Blocking these will break Roku entirely.
- Section 2 covers The Roku Channel. Remove those entries if you don't use it, and optionally uncomment the last regex in `denylist-regex.txt` to block the whole group.
- If The Roku Channel has trouble loading content, the upstream author recommends whitelisting `tis.cti.roku.com` and `ls.cti.roku.com` (already included, still being tested).

---

## Peacock

**Files:**
- [`peacock/allowlist.txt`](peacock/allowlist.txt) — Exact domains required for playback
- [`peacock/allowlist-regex.txt`](peacock/allowlist-regex.txt) — Video CDN regex (required for video to load)
- [`peacock/denylist.txt`](peacock/denylist.txt) — Exact ad-server domain
- [`peacock/denylist-regex.txt`](peacock/denylist-regex.txt) — Ad CDN regex

**Notes:**
- The allowlist regex (`prd-mc`) and denylist regex (`prd-[^.]+`) overlap intentionally. Pi-hole evaluates allowlist regex matches first, so the correct CDN resolves while ad variants are blocked. **Both regex files must be imported for this to work correctly.**
- `mt.ssai.peacocktv.com` has been reported to interfere with Amazon Echo devices. Verify in your environment before blocking it.
- As of July 4, 2025: ads are mostly blocked but videos start from the beginning rather than resuming. Upstream is still investigating.

---

## Paramount+

**Files:**
- [`paramount-plus/allowlist.txt`](paramount-plus/allowlist.txt) — Domains required for service functionality
- [`paramount-plus/allowlist-regex.txt`](paramount-plus/allowlist-regex.txt) — Regex patterns required for video loading
- [`paramount-plus/denylist.txt`](paramount-plus/denylist.txt) — Ad/tracking domains
- [`paramount-plus/denylist-regex.txt`](paramount-plus/denylist-regex.txt) — Regex patterns for ad tech and analytics

**Notes:**
- Paramount+ uses **Google DAI (Dynamic Ad Insertion)**, which embeds ads server-side into the same video stream. `dai.google.com` must be allowed — blocking it stops video playback entirely. This means some ads may still play on Paramount+; there is no way to block them without also blocking the video.
- `imasdk.googleapis.com` is required for streaming on Nvidia Shield and likely other Android TV devices.
- Paramount+ changes its delivery infrastructure frequently. If something breaks, check your Pi-hole query log for newly blocked domains.
- If you use **Unbound with DNSSEC**, browser access to Paramount+ will break even with all allowlist entries applied. Roku still works.

---

## Disney+

**Files:**
- [`disney-plus/denylist-regex.txt`](disney-plus/denylist-regex.txt) — Advertising domains

**Notes:**
- Not tested thoroughly. Community feedback welcome — please open an issue if you have results to share.

---

## Contributing

Found a domain that should be here? Open an issue or PR. Please include:
- The domain or pattern
- The platform and what it's used for (ad, tracking, required for function, etc.)
- How you confirmed it (query log, packet capture, etc.)

All credit for the original domain research goes to **[ozankiratli](https://github.com/ozankiratli)**.
