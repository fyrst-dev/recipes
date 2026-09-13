# Runtime data sync (VPS, no object storage)

**This is not a backup.** Sync clones live → staging / playground / dev. It refuses to restore onto live. Off-host backups with retention, checksums, and a quarterly restore drill are **[backup-runtime.md](backup-runtime.md)** (`deploy/backup-runtime.sh`, cron on **live**). Snapshot on live via this script is allowed and is what the backup wrapper calls.

Pull **database + runtime upload trees** from another Shopware VPS onto this one. Typical direction: **live → staging / playground / dev**.

For a **local** `shopware-cli project dev` tree (path remap into `./public/media/`, `./files/`, …; **no database**; never `SHOPWARE_DATA_ROOT` on the laptop), use **`deploy/sync-runtime-local.sh`**. This document is the VPS bind-mount + DB path.

This is **not** part of image CD. `deploy/vps-release.sh` is unchanged (pull image, setup helper, recreate `web`). Runtime files stay out of git and out of the Shopware app image (`/.dockerignore` already excludes `/deploy` and `/var`).

Operators still run **`deploy/sync-runtime.sh`** (same commands, flags, and `deploy/sync.env` vars). Implementation is sourced from `deploy/lib/` — do not put those files on cron.

Object storage (S3 and similar) is **out of scope** for this VPS path. Transfer is SSH + **`shopware-cli project dump`** (gzip SQL) + **rsync of bind-mount directories** under `SHOPWARE_DATA_ROOT`. Named-volume docker-tar is only a fallback if those directories are missing. Restore still uses the MySQL/MariaDB client (shopware-cli does not replace import).

After recipe updates: `composer recipes:update fyrst/shopware-cd`, then `bash deploy/init-env.sh` (or merge new `.env.example` keys (`SHOPWARE_SHOP_ID`, `SHOPWARE_DEPLOY_ENV`, optional `SHOPWARE_DATA_BASE`) into each environment's `.env` by hand). `COMPOSE_PROJECT_NAME` / `SHOPWARE_DATA_ROOT` are optional script overrides — Compose does not require them.

## Bind mounts (per shop + env)

`deploy/compose.yaml` bind-mounts host dirs into the container (not named volumes). Source of truth is `SHOPWARE_SHOP_ID` + `SHOPWARE_DEPLOY_ENV` (no hardcoded `name: shopware`). Compose concatenates three interpolations (nested `${A:-.../${B}}` defaults do not expand):

```text
# Compose name:  ${SHOPWARE_SHOP_ID}-${SHOPWARE_DEPLOY_ENV}     → acme-live
# Bind-mount:    ${SHOPWARE_DATA_BASE:-/var/lib/shopware/data}/${SHOPWARE_SHOP_ID}/${SHOPWARE_DEPLOY_ENV}
#                → /var/lib/shopware/data/acme/live
```

Optional `SHOPWARE_DATA_BASE=/var/lib/shopware/data`. Optional `COMPOSE_PROJECT_NAME` / `SHOPWARE_DATA_ROOT` only if a script/tool needs the expanded strings — scripts derive them when unset and prefer them when set. Compose does not fail when those two are absent.

| Host (derived data root `/…`) | Container |
| --- | --- |
| `.../files` | `/var/www/html/files` |
| `.../media` | `/var/www/html/public/media` |
| `.../thumbnail` | `/var/www/html/public/thumbnail` |
| `.../theme` | `/var/www/html/public/theme` |
| `.../sitemap` | `/var/www/html/public/sitemap` |

`mysql_data` and `redis_data` stay named volumes, auto-prefixed by the Compose project name (e.g. `acme-live_mysql_data`). Copy SQL with `--data db`, not the `mysql_data` volume.

Live and staging of the same shop on one VPS:

```text
/var/lib/shopware/data/acme/live/media
/var/lib/shopware/data/acme/staging/media
```

A second shop uses a different `SHOPWARE_SHOP_ID` (`widgets` → `widgets-live`, …). Project names stay unique on the Docker host because they include shop id + env.

### One-time bootstrap (each VPS, each shop+env)

```bash
# after setting SHOPWARE_SHOP_ID + SHOPWARE_DEPLOY_ENV in .env
DATA="${SHOPWARE_DATA_BASE:-/var/lib/shopware/data}/${SHOPWARE_SHOP_ID}/${SHOPWARE_DEPLOY_ENV}"
mkdir -p "${DATA}"/{files,media,thumbnail,theme,sitemap}
chown -R 82:82 "${DATA}"
```

(`82` is www-data in `shopware/docker-base`. `deploy/compose.yaml` `init-perm` chowns the same mount points on setup.)

When `SHOPWARE_DATA_ROOT` / `SYNC_DATA_ROOT` are unset, `deploy/sync-runtime.sh` derives `$SHOPWARE_DATA_BASE/$SHOPWARE_SHOP_ID/$SHOPWARE_DEPLOY_ENV` (same path Compose mounts). `--from live` uses `$BASE/$SHOPWARE_SHOP_ID/${SYNC_SOURCE_ENV:-live}` unless `SYNC_REMOTE_DATA_ROOT` is set. Missing `SHOPWARE_SHOP_ID` is refused.

## What is copied

Default `--data all` (same as omitting `--data`):

| Item | Mechanism |
| --- | --- |
| `db` | Logical SQL dump via `shopware-cli project dump` (one-shot `ghcr.io/shopware/shopware-cli:0.18.4` on the Compose network, or `--network host` for `DATABASE_URL`). Restore is still `mysql`/`mariadb` client import. |
| `media` `files` `thumbnail` `theme` `sitemap` | rsync of `$SHOPWARE_DATA_ROOT/<item>/` (source → dest). Tar + docker extract if rsync cannot write uid 82; named-volume tar only if the bind-mount dir is missing |

Do not put dumps in git.

## Host packages

On **every** VPS that snapshots or restores:

- Docker Engine + Compose v2 plugin
- bash
- OpenSSH client
- gzip (restore + bind-mount tar fallback)
- **rsync** (incremental live → staging of bind-mount trees; tar is the fallback)
- Registry access to pull **`ghcr.io/shopware/shopware-cli:0.18.4`** (dumps). The compose `web` image does **not** ship shopware-cli.

The SSH user must be able to run `docker` (typically the `docker` group). Direct rsync into `SHOPWARE_DATA_ROOT` needs write access (cron as root, or the script chowns via a one-shot container).

## One-time setup (consumer)

On staging (or playground/dev), not on live:

1. Create the bind-mount dirs as above. Set `SHOPWARE_SHOP_ID` and `SHOPWARE_DEPLOY_ENV` in `.env` (optional `SHOPWARE_DATA_BASE`). Compose does not need `COMPOSE_PROJECT_NAME` / `SHOPWARE_DATA_ROOT`.
2. Copy `deploy/sync.env.example` → `deploy/sync.env` and `chmod 600 deploy/sync.env`.
3. Set `SYNC_ENV=staging` (or `playground` / `dev`). **Never** set `SYNC_ENV=live` or `SHOPWARE_DEPLOY_ENV=live` on a host you restore onto.
4. Fill `SYNC_SSH_*` and `SYNC_REMOTE_PATH` for the source (live checkout, e.g. `/opt/shopware/acme-live`). `SYNC_DATA_ROOT` / `SYNC_REMOTE_DATA_ROOT` only if they differ from the derived `$BASE/$SHOPWARE_SHOP_ID/<env>` paths. Optional: `SYNC_SOURCE_ENV=live`.
5. Install an SSH key that can log in to live **without a passphrase** (cron). Pin `known_hosts`.
6. Confirm shop-root `.env` has `IMAGE` (compose interpolation; same as release). Sync does not read secrets from the script itself.

Do not commit `deploy/sync.env` (add it to the shop `.gitignore`; that file is owned by `shopware-cli project create`).

Live should still have `SYNC_ENV=live` and `SHOPWARE_DEPLOY_ENV=live` in its own env files if they exist, so a mistaken `restore`/`sync` on live is refused. Snapshot on live is allowed (used by `deploy/backup-runtime.sh`). Live disaster restore is `BACKUP_ALLOW_LIVE_RESTORE=1` on the backup script, not a normal sync.

## Commands

Run from the **shop root** (or rely on the script `cd` to the parent of `deploy/`):

```bash
# Preview (no dump/copy/restore)
bash deploy/sync-runtime.sh sync --from live --data all --dry-run

# Cron path: shopware-cli dump of live DB, rsync SHOPWARE_DATA_ROOT trees, restore DB here
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

### Database dump (`shopware-cli project dump`)

Production Shopware images do **not** include shopware-cli. Sync/backup start a **one-shot container** from the pinned official image, join the Compose network so hostname `mysql` resolves, and mount the shop root so `.env` / `.shopware-project.yml` (`dump.ignore` / `dump.rewrite`) are visible:

```text
docker run --rm --network ${COMPOSE_PROJECT_NAME}_default \
  -v <shop-root>:<shop-root>:ro -v <snapshot-dir>:<snapshot-dir> -w <shop-root> \
  ghcr.io/shopware/shopware-cli:0.18.4 \
  --no-update-hint project dump \
  --skip-lock-tables --quick --clean --compression=gzip \
  --output <snapshot-dir>/db.sql.gz \
  --host mysql --port 3306 --username … --database …
```

Pin: **`ghcr.io/shopware/shopware-cli:0.18.4`**. Override with `SYNC_SHOPWARE_CLI_IMAGE`. If the image cannot be pulled, the script **fails** with `docker pull` guidance — it does **not** fall back to mysqldump. Escape hatch: `SYNC_DUMP_ENGINE=mysqldump`.

| Env | Default | Effect |
| --- | --- | --- |
| `SYNC_DUMP_CLEAN` | `1` | `--clean` (skip cart / messenger / log noise). `0` keeps those rows. |
| `SYNC_DUMP_ANONYMIZE` | `0` | `1` adds `--anonymize` (usually off for live→staging) |
| `SYNC_DUMP_QUICK` | `1` | `--quick`. `0` opts out. |
| `SYNC_DUMP_ENGINE` | `shopware-cli` | `mysqldump` = old compose-exec / client-image dump |

Restore is unchanged: `gzip -dc db.sql.gz` piped into `mysql`/`mariadb` (compose exec or `--network host` client). shopware-cli is dump-only.

### Cron (consumer)

```cron
15 2 * * * cd /opt/shopware/acme-staging && bash deploy/sync-runtime.sh sync --from live --data all
```

Overlapping runs are blocked with `flock` on `var/runtime-sync.lock`.

## After restore

- The script tries `bin/console cache:clear` via compose `web` and **does not fail the sync** if that errors.
- **Sales-channel domains are not rewritten unless you opt in.** Default behaviour is unchanged: the restored DB still has the source (usually live) `sales_channel_domain.url` rows.
- **Opt-in rewrite** (staging / playground / dev only — **hard-refused on live**, including `SYNC_ALLOW_LIVE_RESTORE=1`):

  ```bash
  # replace scheme+host(+port) on every sales_channel_domain.url; keep the path
  SYNC_REWRITE_APP_URL=https://staging.example.com

  # or a 1:1 prefix map (longest match first) when shops have several origins
  # SYNC_REWRITE_URL_MAP=https://shop.example.com=https://staging.example.com,https://b2b.example.com=https://b2b.staging.example.com
  ```

  After the DB restore, sync calls `bin/console fyrst:sales-channel:rewrite-urls` via compose `web` (same `run --rm --pull never --entrypoint php` style as `cache:clear`). Shops need a current `fyrst/shopware-cd` so that command and `FyrstShopwareCdBundle` exist:

  ```bash
  composer update fyrst/shopware-cd
  composer recipes:update fyrst/shopware-cd
  ```

  (`recipes:update` writes `Fyrst\ShopwareCd\FyrstShopwareCdBundle` into `config/bundles.php`.) The command updates `sales_channel_domain.url` only. It does **not** half-update media CDN, plugin `system_config`, or payment/shipping webhook URLs — those still need **manual review**. Optional: `SYNC_POST_RESTORE_CMD` for a shop-specific extra hook (non-fatal).
- Without the rewrite env, set `SYNC_APP_URL` (or rely on `APP_URL` in `.env`) so the log prints the destination URL if you rewrite in admin yourself.

## Safety

- Restore and sync **refuse** when `SYNC_ENV=live`, `SHOPWARE_DEPLOY_ENV=live`, or the checkout directory is named `live` (e.g. `/opt/shopware/live`).
- Convention is pull-only: never “push” onto live.
- Dumps contain customer data: `umask 077` on the snapshot directory.

## External database

If the bundled `mysql` service was removed, a **local** snapshot uses `shopware-cli project dump` with `--network host` and credentials from `DATABASE_URL`. Restore still uses a one-shot `mysql`/`mariadb` client container (`--network host`). A **remote** dump over SSH requires the source to still have compose `mysql`, or run `snapshot --from local` on the source and copy `var/runtime-sync` yourself.

## Named-volume fallback

If `$SHOPWARE_DATA_ROOT/<item>` does not exist but a leftover compose volume `${COMPOSE_PROJECT_NAME}_<item>` does, the script tars that volume. New shops should use bind mounts only.

## Local project-dev pull

`deploy/sync-runtime-local.sh` reads `SHOPWARE_SHOP_ID` from the laptop `.env` and rsyncs from

`/var/lib/shopware/data/${SHOPWARE_SHOP_ID}/live`

(override with `--remote-data-root` / `SYNC_REMOTE_DATA_ROOT` / `SYNC_SOURCE_ENV`). Destinations stay in the project tree (`./public/media/`, `./files/`, …). Requires `SHOPWARE_SHOP_ID` unless an explicit remote root is set.
