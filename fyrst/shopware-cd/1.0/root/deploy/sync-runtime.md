# Runtime data sync (VPS, no object storage)

**This is not a backup.** Sync clones live → staging / playground / dev. It refuses to restore onto live. Off-host backups with retention, checksums, and a quarterly restore drill are **[backup-runtime.md](backup-runtime.md)** (`fyrst-cli shopware backup`, cron on **live**). Volume capture on live is allowed. Dump stays **`shopware-cli project dump`**.

Pull **database + runtime upload trees** from another Shopware VPS onto this one. Typical direction: **live → staging / playground / dev**.

For a **local** `shopware-cli project dev` tree (path remap into `./public/media/`, `./files/`, …; **no database**; never `SHOPWARE_DATA_ROOT` on the laptop), use **`fyrst-cli shopware sync local`**. `--data all` is refused on that verb. This document is the VPS bind-mount + DB path.

This is **not** part of image CD. `fyrst-cli shopware deploy release` still pulls the image, runs setup, and recreates `web`. Runtime files stay out of git and out of the Shopware app image (`/.dockerignore` already excludes `/deploy` and `/var`).

| Command | Role |
| --- | --- |
| `fyrst-cli shopware sync capture` | This host (or `--from`) → `--snapshot-dir` |
| `fyrst-cli shopware sync apply` | `--snapshot-dir` onto this host |
| `fyrst-cli shopware sync pull` | Consumer cron: rsync `--from` + import existing dump |
| `fyrst-cli shopware sync local` | VPS → laptop project-dev (never DB; `--data all` refused) |

Object storage (S3 and similar) is **out of scope** for this VPS path. Transfer is SSH + **rsync of bind-mount directories** under `SHOPWARE_DATA_ROOT`. **Dump is operator-run `shopware-cli project dump`** — fyrst-cli never dumps. Named-volume docker-tar is only a fallback if those directories are missing. Restore uses `fyrst-cli shopware db import` (MySQL/MariaDB client).

After recipe updates: `composer recipes:update fyrst/shopware-cd`, then `fyrst-cli shopware env init` (or merge new `.env.example` keys (`SHOPWARE_SHOP_ID`, `SHOPWARE_DEPLOY_ENV`, optional `SHOPWARE_DATA_BASE`) into each environment's `.env` by hand). `COMPOSE_PROJECT_NAME` / `SHOPWARE_DATA_ROOT` are optional overrides — Compose does not require them.

## Bind mounts (per shop + env)

`deploy/compose.yaml` bind-mounts host dirs into the container (not named volumes). Source of truth is `SHOPWARE_SHOP_ID` + `SHOPWARE_DEPLOY_ENV` (no hardcoded `name: shopware`). Compose concatenates three interpolations (nested `${A:-.../${B}}` defaults do not expand):

```text
# Compose name:  ${SHOPWARE_SHOP_ID}-${SHOPWARE_DEPLOY_ENV}     → acme-live
# Bind-mount:    ${SHOPWARE_DATA_BASE:-/var/lib/shopware/data}/${SHOPWARE_SHOP_ID}/${SHOPWARE_DEPLOY_ENV}
#                → /var/lib/shopware/data/acme/live
```

Optional `SHOPWARE_DATA_BASE=/var/lib/shopware/data`. Optional `COMPOSE_PROJECT_NAME` / `SHOPWARE_DATA_ROOT` only if a script/tool needs the expanded strings — fyrst-cli derives them when unset and prefers them when set. Compose does not fail when those two are absent.

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

When `SHOPWARE_DATA_ROOT` / `SYNC_DATA_ROOT` are unset, fyrst-cli derives `$SHOPWARE_DATA_BASE/$SHOPWARE_SHOP_ID/$SHOPWARE_DEPLOY_ENV` (same path Compose mounts). `--from live` uses `$BASE/$SHOPWARE_SHOP_ID/${SYNC_SOURCE_ENV:-live}` unless `SYNC_REMOTE_DATA_ROOT` is set. Missing `SHOPWARE_SHOP_ID` is refused.

## What is copied

Default `--data all` on `sync pull` / `sync capture` (same as omitting `--data`):

| Item | Mechanism |
| --- | --- |
| `db` | Operator-run `shopware-cli project dump` into `--snapshot-dir/db.sql.gz`. fyrst-cli never dumps (`sync capture --data db` exits 2 with that instruction). Restore is `fyrst-cli shopware db import`. |
| `media` `files` `thumbnail` `theme` `sitemap` | rsync of `$SHOPWARE_DATA_ROOT/<item>/` (source → dest). Tar + docker extract if rsync cannot write uid 82; named-volume tar only if the bind-mount dir is missing |

Do not put dumps in git. `--data all` is **refused** on `sync local`.

## Host packages

On **every** VPS that captures or applies:

- Docker Engine + Compose v2 plugin
- bash
- OpenSSH client
- gzip (restore + bind-mount tar fallback)
- **rsync** (incremental live → staging of bind-mount trees; tar is the fallback)
- **fyrst-cli 0.1.0+** on PATH (install on each VPS)
- **shopware-cli** on hosts that dump (fyrst-cli never dumps)

The SSH user must be able to run `docker` (typically the `docker` group). Direct rsync into `SHOPWARE_DATA_ROOT` needs write access (cron as root, or a one-shot container chowns).

## One-time setup (consumer)

On staging (or playground/dev), not on live:

1. Create the bind-mount dirs as above. Set `SHOPWARE_SHOP_ID` and `SHOPWARE_DEPLOY_ENV` in `.env` (optional `SHOPWARE_DATA_BASE`). Compose does not need `COMPOSE_PROJECT_NAME` / `SHOPWARE_DATA_ROOT`.
2. Copy `deploy/sync.env.example` → `deploy/sync.env` and `chmod 600 deploy/sync.env`.
3. Set `SYNC_ENV=staging` (or `playground` / `dev`). **Never** set `SYNC_ENV=live` or `SHOPWARE_DEPLOY_ENV=live` on a host you restore onto.
4. Fill `SYNC_SSH_*` and `SYNC_REMOTE_PATH` for the source (live checkout, e.g. `/opt/shopware/acme-live`). `SYNC_DATA_ROOT` / `SYNC_REMOTE_DATA_ROOT` only if they differ from the derived `$BASE/$SHOPWARE_SHOP_ID/<env>` paths. Optional: `SYNC_SOURCE_ENV=live`.
5. Install an SSH key that can log in to live **without a passphrase** (cron). Pin `known_hosts`.
6. Confirm shop-root `.env` has `IMAGE` (compose interpolation; same as release). fyrst-cli does not read secrets from this document.

Do not commit `deploy/sync.env` (add it to the shop `.gitignore`; that file is owned by `shopware-cli project create`).

Live should still have `SYNC_ENV=live` and `SHOPWARE_DEPLOY_ENV=live` in its own env files if they exist, so a mistaken `apply`/`pull` on live is refused. Volume capture on live is allowed. Live disaster restore is `BACKUP_ALLOW_LIVE_RESTORE=1` on backup recover, not a normal sync.

## Commands

Run from the **shop root** (or set `COMPOSE_DIR`):

```bash
# Preview (no dump/copy/restore)
fyrst-cli shopware sync pull --from live --data all --dry-run

# Cron path: rsync trees + import an already-present db.sql.gz (does not dump)
fyrst-cli shopware sync pull --from live --data all

# Snapshot only (this host → --snapshot-dir)
fyrst-cli shopware sync capture --from local --data all

# Snapshot live into ./var/runtime-sync (no restore)
fyrst-cli shopware sync capture --from live --data all

# Restore an existing snapshot directory
fyrst-cli shopware sync apply --data all --snapshot-dir ./var/runtime-sync
```

Flags:

| Flag | Meaning |
| --- | --- |
| `--from <alias>` | `local` or SSH source. `--from live` uses `SYNC_SSH_*` / `SYNC_LIVE_*` / ssh `Host live` |
| `--data <list>\|all` | `db,media,files,thumbnail,theme,sitemap` (`sync local` refuses `all`) |
| `--snapshot-dir <dir>` | Default `<shop>/var/runtime-sync` (Shopware `/var` is gitignored) |
| `--dry-run` | Log actions only |
| `--skip-db` / `--skip-volumes` | Subtract db or the bind-mount trees from `--data` |

### Database dump (`shopware-cli project dump` only)

fyrst-cli **does not dump**. On the source, run shopware-cli yourself and place `db.sql.gz` in `--snapshot-dir` (default `<shop>/var/runtime-sync`) before `sync pull` / `sync apply`, or import with `fyrst-cli shopware db import --file`.

```bash
shopware-cli project dump --skip-lock-tables --compression=gzip --output db.sql.gz
```

See the [Shopware CLI dump docs](https://developer.shopware.com/docs/products/tools/cli/project-commands/mysql-dump.html). `sync capture --data db` exits 2 with that instruction (not a silent success). Restore is `fyrst-cli shopware db import` (compose `mysql` exec or a one-shot client).

### Cron (consumer)

```cron
15 2 * * * cd /opt/shopware/acme-staging && fyrst-cli shopware sync pull --from live --data all
```

Overlapping runs are blocked with `flock` on `var/runtime-sync.lock`.

## After restore

- fyrst-cli tries `bin/console cache:clear` via compose `web` and **does not fail the sync** if that errors.
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

- Apply and pull **refuse** when `SYNC_ENV=live`, `SHOPWARE_DEPLOY_ENV=live`, or the checkout directory is named `live` (e.g. `/opt/shopware/live`).
- Convention is pull-only: never “push” onto live.
- Dumps contain customer data: `umask 077` on the snapshot directory.

## External database

If the bundled `mysql` service was removed, dump with shopware-cli against `DATABASE_URL` on the source. Restore still uses a one-shot `mysql`/`mariadb` client container (`--network host`) via `fyrst-cli shopware db import`. Copy `db.sql.gz` into `--snapshot-dir` yourself.

## Named-volume fallback

If `$SHOPWARE_DATA_ROOT/<item>` does not exist but a leftover compose volume `${COMPOSE_PROJECT_NAME}_<item>` does, fyrst-cli tars that volume. New shops should use bind mounts only.

## Local project-dev pull

`fyrst-cli shopware sync local` reads `SHOPWARE_SHOP_ID` from the laptop `.env` and rsyncs from

`/var/lib/shopware/data/${SHOPWARE_SHOP_ID}/live`

(override with `--remote-data-root` / `SYNC_REMOTE_DATA_ROOT` / `SYNC_SOURCE_ENV`). Destinations stay in the project tree (`./public/media/`, `./files/`, …). Requires `SHOPWARE_SHOP_ID` unless an explicit remote root is set. `--data all` is refused.
