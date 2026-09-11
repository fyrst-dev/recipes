# Runtime data sync (VPS, no object storage)

Pull **database + runtime upload trees** from another Shopware VPS onto this one. Typical direction: **live → staging / playground / dev**.

This is **not** part of image CD. `deploy/vps-release.sh` is unchanged (pull image, setup helper, recreate `web`). Runtime files stay out of git and out of the Shopware app image (`/.dockerignore` already excludes `/deploy` and `/var`).

Object storage (S3 and similar) is **out of scope** for this VPS path. Transfer is SSH + `mysqldump`/`mariadb-dump` + **rsync of bind-mount directories** under `SHOPWARE_DATA_ROOT`. Named-volume docker-tar is only a fallback if those directories are missing.

## Bind mounts (default)

`deploy/compose.yaml` bind-mounts host dirs into the container (not named volumes):

| Host (`SHOPWARE_DATA_ROOT`, default `/var/lib/shopware/data`) | Container |
| --- | --- |
| `.../files` | `/var/www/html/files` |
| `.../media` | `/var/www/html/public/media` |
| `.../thumbnail` | `/var/www/html/public/thumbnail` |
| `.../theme` | `/var/www/html/public/theme` |
| `.../sitemap` | `/var/www/html/public/sitemap` |

`mysql_data` and `redis_data` stay named volumes. Copy SQL with `--data db`, not the `mysql_data` volume.

### One-time bootstrap (each VPS)

```bash
mkdir -p /var/lib/shopware/data/{files,media,thumbnail,theme,sitemap}
chown -R 82:82 /var/lib/shopware/data
```

(`82` is www-data in `shopware/docker-base`. `deploy/compose.yaml` `init-perm` chowns the same mount points on setup.) Set `SHOPWARE_DATA_ROOT` in shop-root `.env`. `SYNC_DATA_ROOT` in `deploy/sync.env` follows that value when unset.

## What is copied

Default `--data all` (same as omitting `--data`):

| Item | Mechanism |
| --- | --- |
| `db` | Logical SQL dump from the bundled compose `mysql` service (or `DATABASE_URL` on this host) |
| `media` `files` `thumbnail` `theme` `sitemap` | rsync of `$SHOPWARE_DATA_ROOT/<item>/` (source → dest). Tar + docker extract if rsync cannot write uid 82; named-volume tar only if the bind-mount dir is missing |

Do not put dumps in git.

## Host packages

On **every** VPS that snapshots or restores:

- Docker Engine + Compose v2 plugin
- bash
- OpenSSH client
- gzip
- **rsync** (incremental live → staging of bind-mount trees; tar is the fallback)

The SSH user must be able to run `docker` (typically the `docker` group). Direct rsync into `SHOPWARE_DATA_ROOT` needs write access (cron as root, or the script chowns via a one-shot container).

## One-time setup (consumer)

On staging (or playground/dev), not on live:

1. Create `SHOPWARE_DATA_ROOT` as above and set it in `.env`.
2. Copy `deploy/sync.env.example` → `deploy/sync.env` and `chmod 600 deploy/sync.env`.
3. Set `SYNC_ENV=staging` (or `playground` / `dev`). **Never** set `SYNC_ENV=live` on a host you restore onto.
4. Fill `SYNC_SSH_*` and `SYNC_REMOTE_PATH` for the source (live checkout, e.g. `/opt/shopware/live`). `SYNC_DATA_ROOT` / `SYNC_REMOTE_DATA_ROOT` only if they differ from `SHOPWARE_DATA_ROOT`.
5. Install an SSH key that can log in to live **without a passphrase** (cron). Pin `known_hosts`.
6. Confirm shop-root `.env` has `IMAGE` (compose interpolation; same as release). Sync does not read secrets from the script itself.

Do not commit `deploy/sync.env` (add it to the shop `.gitignore`; that file is owned by `shopware-cli project create`).

Live should still have `SYNC_ENV=live` in its own `deploy/sync.env` if that file exists, so a mistaken `restore`/`sync` on live is refused. Snapshot on live is allowed (backups).

## Commands

Run from the **shop root** (or rely on the script `cd` to the parent of `deploy/`):

```bash
# Preview (no dump/copy/restore)
bash deploy/sync-runtime.sh sync --from live --data all --dry-run

# Cron path: dump live DB, rsync SHOPWARE_DATA_ROOT trees, restore DB here
bash deploy/sync-runtime.sh sync --from live --data all

# Snapshot only (this host → --snapshot-dir)
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
| `--skip-db` / `--skip-volumes` | Subtract db or the bind-mount trees from `--data` |

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

## Named-volume fallback

If `$SHOPWARE_DATA_ROOT/<item>` does not exist but a leftover compose volume `shopware_<item>` does, the script tars that volume. New shops should use bind mounts only.
