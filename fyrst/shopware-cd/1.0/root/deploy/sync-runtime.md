# Runtime data sync (VPS, no object storage)

Pull **database + runtime volumes** from another Shopware VPS onto this one. Typical direction: **live → staging / playground / dev**.

This is **not** part of image CD. `deploy/vps-release.sh` is unchanged (pull image, setup helper, recreate `web`). Runtime files stay out of git and out of the Shopware app image (`/.dockerignore` already excludes `/deploy` and `/var`).

Object storage (S3 and similar) is **out of scope** for this VPS path. Transfer is SSH + `mysqldump`/`mariadb-dump` + docker volume tar (rsync when the source wrote a snapshot directory).

## What is copied

Default `--data all` (same as omitting `--data`):

| Item | Mechanism |
| --- | --- |
| `db` | Logical SQL dump from the bundled compose `mysql` service (or `DATABASE_URL` on this host) |
| `media` `files` `thumbnail` `theme` `sitemap` | Named Docker volumes on compose project `shopware` (`shopware_media`, …) |

Not copied: `mysql_data` / `redis_data` volumes (use `db` for SQL; Redis is ephemeral for this recipe). Do not put dumps in git.

## Host packages

On **every** VPS that snapshots or restores:

- Docker Engine + Compose v2 plugin
- bash
- OpenSSH client
- gzip

`rsync` is recommended when the source checkout already contains `deploy/sync-runtime.sh` (copies `var/runtime-sync` as a tree). Without rsync, the script streams `tar` over SSH.

The SSH user must be able to run `docker` (typically the `docker` group).

## One-time setup (consumer)

On staging (or playground/dev), not on live:

1. Copy `deploy/sync.env.example` → `deploy/sync.env` and `chmod 600 deploy/sync.env`.
2. Set `SYNC_ENV=staging` (or `playground` / `dev`). **Never** set `SYNC_ENV=live` on a host you restore onto.
3. Fill `SYNC_SSH_*` and `SYNC_REMOTE_PATH` for the source (live checkout, e.g. `/opt/shopware/live`).
4. Install an SSH key that can log in to live **without a passphrase** (cron). Pin `known_hosts`.
5. Confirm shop-root `.env` has `IMAGE` (compose interpolation; same as release). Sync does not read secrets from the script itself.

Do not commit `deploy/sync.env` (add it to the shop `.gitignore`; that file is owned by `shopware-cli project create`).

Live should still have `SYNC_ENV=live` in its own `deploy/sync.env` if that file exists, so a mistaken `restore`/`sync` on live is refused. Snapshot on live is allowed (backups).

## Commands

Run from the **shop root** (or rely on the script `cd` to the parent of `deploy/`):

```bash
# Preview (no dump/copy/restore)
bash deploy/sync-runtime.sh sync --from live --data all --dry-run

# Cron path: snapshot live, restore here
bash deploy/sync-runtime.sh sync --from live --data all

# Snapshot only (this host)
bash deploy/sync-runtime.sh snapshot --from local --data all

# Snapshot live into ./var/runtime-sync (no restore)
bash deploy/sync-runtime.sh snapshot --from live --data all

# Restore an existing snapshot directory
bash deploy/sync-runtime.sh restore --data all --snapshot-dir ./var/runtime-sync
```

Flags:

| Flag | Meaning |
| --- | --- |
| `--from <alias>` | `local` or SSH source. `--from live` uses `SYNC_SSH_*` / `SYNC_LIVE_*` / ssh `Host live` |
| `--data <list>\|all` | `db,media,files,thumbnail,theme,sitemap` |
| `--snapshot-dir <dir>` | Default `<shop>/var/runtime-sync` (Shopware `/var` is gitignored) |
| `--dry-run` | Log actions only |
| `--skip-db` / `--skip-volumes` | Subtract from `--data` |

### Cron (consumer)

```cron
15 2 * * * cd /opt/shopware/staging && bash deploy/sync-runtime.sh sync --from live --data all
```

Overlapping runs are blocked with `flock` on `var/runtime-sync.lock`.

## After restore

- The script tries `bin/console cache:clear` via compose `web` and **does not fail the sync** if that errors.
- **Sales-channel URLs still point at the source.** There is no single Shopware core command that is safe for every project. Set `SYNC_APP_URL` (or rely on `APP_URL` in `.env`) so the log prints the destination URL, then rewrite `sales_channel_domain` in admin or SQL. Optional: `SYNC_POST_RESTORE_CMD` for a shop-specific console/SQL hook (non-fatal).

## Safety

- Restore and sync **refuse** when `SYNC_ENV=live` or the checkout directory is named `live` (e.g. `/opt/shopware/live`).
- Convention is pull-only: never “push” onto live.
- Dumps contain customer data: `umask 077` on the snapshot directory.

## External database

If the bundled `mysql` service was removed, a **local** snapshot/restore uses `DATABASE_URL` and a one-shot `mysql`/`mariadb` client container (`--network host`). A **remote** dump over SSH requires the source to still have compose `mysql`, or run `snapshot --from local` on the source and copy `var/runtime-sync` yourself.

## Bind mounts

This recipe’s `deploy/compose.yaml` uses named volumes. If you replaced them with bind mounts, export/rsync those host paths into the same files under `--snapshot-dir/volumes/<name>.tar.gz` (or put the script’s `SYNC_ARCHIVE_IMAGE` tar aside and copy files with rsync). Named-volume export is the supported path.
