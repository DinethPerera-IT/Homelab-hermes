# TODO: Upgrade Uptime Kuma 1.23.17 → 2.5.x

**Status:** Parked (18 November 2026). Nothing has been changed. Run this when there's a quiet window.

## Why
- Uptime Kuma **2.5.11** (released 12 Nov 2026) fixes **GHSA-437w-j82f-9vjh**: "[Admin Only] RCE via an upstream
  package's regression". Full details are due about 7 days after release. It's not confirmed yet whether 1.23.x is
  affected ("regression" suggests it may be 2.x-only), but 1.x is the old line either way.
- We're on **1.23.17**, a full major version behind.

## Current state (checked 18 Nov 2026)
| Item | Value |
|---|---|
| Version | **1.23.17** |
| Image | `louislam/uptime-kuma:latest` |
| Why it never upgraded | On Docker Hub **`latest` is the same image as `1`** (the v1 line), so pulling `latest` never reaches 2.x |
| How it runs | Plain `docker run` (no compose file) |
| Data | Named volume `uptime-kuma` → `/app/data` (SQLite `kuma.db` ~120 MB + WAL) |
| Port | `3001` published on **all interfaces** (LAN included) |
| Restart policy | `always` |
| Used by | Homepage widget (`http://<lan-ip>:3001`), Caddy `uptime.dinashomelab.internal`, status page `/status/dinashomelab` |

## v1 → v2 risks
- **The database is migrated in place.** Heartbeat data is aggregated into a new format. It took ~7 minutes for the
  author's instance (20 monitors, 90 days of data), and the docs say it "can take hours" on slower hardware.
  **Never interrupt the migration.** If it's interrupted, restore from backup and retry.
- **No downgrade.** v1 can't read a migrated database. The only way back is restoring the data backup.
- **JSON backup/restore is removed in v2.** Backing up the `data` folder is the only supported method.
- **Breaking changes:**
  - New monitors default to 0 retries (was 1).
  - The HTTP monitor DNS cache was removed.
  - SMTP email templates moved to LiquidJS (case-sensitive variables).
  - Badge `:duration` format changed.
  - Legacy browsers are no longer supported.
- **Image variants:** don't use `*-rootless` for a v1→v2 upgrade (startup issues). Alpine images are gone. Use the
  normal (or `-slim`) image.
- **No monitoring during the upgrade.** Kuma is the backup monitor, and Lookout is currently disabled, so nothing
  watches the homelab while Kuma is stopped and migrating. Pick a quiet time.

## Plan

### 1. Prepare (no downtime)
1. **Pin the newest 2.5.x, not `latest` or `2`.** Check Docker Hub tags and the GitHub releases page on the day. (On
   18 Nov the `2` tag had been pushed after 2.5.11, so a newer 2.5.x may exist.) Read its release notes.
2. **JSON export reminder:** in the v1 UI, go to **Settings → Backup → Export** and download a JSON export. This is
   the last chance, because v2 removed the feature. It's an extra copy of monitors and notifications for reference or a
   fresh v1. **It may contain notification secrets (webhooks, tokens): store it with backups, never in git.**
3. Save the current run settings:
   `docker inspect uptime-kuma > ~/backups/uptime-kuma-inspect-<date>.json`
4. Write `~/uptime-kuma/docker-compose.yml` (heredoc):
   - pinned image `louislam/uptime-kuma:2.5.<x>`
   - the existing named volume `uptime-kuma` (declared `external: true`) mounted at `/app/data`
   - port `3001:3001`, unchanged so Homepage and Caddy keep working (tightened in step 6)
   - `restart: unless-stopped`
   - Validate with `docker compose config`, then download ahead of time with `docker compose pull`.

### 2. Back up (downtime starts)
1. `docker stop uptime-kuma` (a clean stop gives a consistent SQLite copy, with the WAL included)
2. `sudo tar -C /var/lib/docker/volumes/uptime-kuma -czpf ~/backups/uptime-kuma-v1.23.17-<date>.tar.gz _data`
3. Verify: `tar -tzf <file> | head`, check the size is about 120 MB, and save `sha256sum` next to it.
4. Keep the old container for rollback: `docker rename uptime-kuma uptime-kuma-v1` and
   `docker update --restart=no uptime-kuma-v1`

### 3. Upgrade
1. `cd ~/uptime-kuma && docker compose up -d`
2. `docker logs -f uptime-kuma`: watch the migration until it finishes. No restarts and no reboots while it runs.

### 4. Verify
- The UI shows the pinned 2.5.x version.
- All monitors are present and up (6 sites up before the upgrade).
- A notification test arrives.
- `http://uptime.dinashomelab.internal/status/dinashomelab` loads through Caddy.
- The Homepage Uptime Kuma widget shows data.
- Check the breaking changes above: monitor retries, SMTP templates if email notifications are used.

### 5. Rollback (if anything is wrong)
1. `cd ~/uptime-kuma && docker compose down`
2. Restore the data, which is required because v2 migrated the DB in place:
   `sudo rm -rf /var/lib/docker/volumes/uptime-kuma/_data/*` then
   `sudo tar -C /var/lib/docker/volumes/uptime-kuma -xzpf ~/backups/uptime-kuma-v1.23.17-<date>.tar.gz`
3. `docker rename uptime-kuma-v1 uptime-kuma && docker update --restart=always uptime-kuma && docker start uptime-kuma`
4. You're back on 1.23.17 with the data from before the upgrade.

### 6. Afterwards
- **Tighten port 3001.** It's currently published on every interface, LAN included.
  - Bind it to `127.0.0.1:3001:3001` and reach Kuma only through Caddy (`uptime.dinashomelab.internal`).
  - Before changing it, update the Homepage widget URL (`http://<lan-ip>:3001`) to a URL Homepage can still reach,
    and update any other direct users of `:3001`.
  - Check with `ss -tlnp | grep 3001`.
- After about a week of normal running: `docker rm uptime-kuma-v1` and remove the old image.
- Re-enable Lookout when build work settles. Update homelab notes, Homepage, and the repo.

## Sources
- Release 2.5.11: https://github.com/louislam/uptime-kuma/releases/tag/2.5.11
- Migration guide: https://github.com/louislam/uptime-kuma/wiki/Migration-From-v1-To-v2
- Docker Hub tags: https://hub.docker.com/r/louislam/uptime-kuma/tags
