# VPS backup (not sync)

**`fyrst-cli shopware sync` is not a backup.** Sync clones live → staging/playground/dev. It refuses to restore onto live. Live MySQL (`mysql_data` named volume) and bind mounts under the derived data root sit on the **same VPS disk** as the checkout. Disk loss or a bad restore-from-live onto the wrong host is not covered by sync.

This file is the **backup** path: timestamped artifacts on another disk or another host, with retention, checksums, and a restore drill. Install fyrst-cli 0.1.0+ on live.

| Command | Role |
| --- | --- |
| `fyrst-cli shopware backup create` | Copy artifacts into `BACKUP_TARGET` (live allowed) |
| `fyrst-cli shopware backup prune` | Stamp-based retention |
| `fyrst-cli shopware backup recover` | Disaster recovery onto this host |

Non-goals: WAL shipping / PITR, S3.

## What is copied

Same trees as sync `--data all`:

| Item | Mechanism |
| --- | --- |
| `db` | Operator-run `shopware-cli project dump`. Set `BACKUP_DB_DUMP` to that `db.sql.gz`. fyrst-cli never dumps. Restore is `fyrst-cli shopware db import`. |
| `media` `files` `thumbnail` `theme` `sitemap` | Bind-mount trees under `$SHOPWARE_DATA_BASE/$SHOPWARE_SHOP_ID/$SHOPWARE_DEPLOY_ENV` |

Layout on `BACKUP_TARGET`:

```text
$BACKUP_TARGET/$SHOPWARE_SHOP_ID/$SHOPWARE_DEPLOY_ENV/YYYYMMDDTHHMMSSZ/
  db.sql.gz
  data/media/ …
  MANIFEST.txt          # from sync capture
  BACKUP_MANIFEST.txt  # shop id, env, target
  SHA256SUMS
```

## One-time setup (live)

On the **live** VPS (unlike sync, which you configure on staging):

1. Copy `deploy/backup.env.example` → `deploy/backup.env` and `chmod 600 deploy/backup.env`.
2. Set `BACKUP_TARGET` to a **second disk** or an **SSH host** (not only a directory on the same root filesystem as `/var/lib/shopware`). Same-disk copies are better than nothing but do not survive disk loss.
3. `SHOPWARE_SHOP_ID` + `SHOPWARE_DEPLOY_ENV=live` in shop-root `.env` (same as Compose).
4. Install **fyrst-cli 0.1.0+**. Dump with shopware-cli yourself and set `BACKUP_DB_DUMP` when `--data` includes db. Shop-root `.env` still needs `IMAGE` for compose interpolation.

Do not commit `deploy/backup.env`.

## Commands

```bash
# Preview (no dump). Allowed on live.
fyrst-cli shopware backup create --dry-run

# Nightly (live)
fyrst-cli shopware backup create

# Retention only
fyrst-cli shopware backup prune

# Restore onto this host (staging drill — no live flag)
fyrst-cli shopware backup recover --from 20260912T020000Z \
  --i-understand-this-restores-this-host
```

`backup create` always prunes after a successful snapshot. `BACKUP_KEEP_DAYS` (default 14, `0` = keep forever) deletes artifact directories whose **timestamp name** `YYYYMMDDTHHMMSSZ` is older than that many days (UTC).

## Cron (live)

```cron
20 2 * * * cd /opt/shopware/acme-live && fyrst-cli shopware backup create
```

Overlapping runs are blocked with `flock` on `var/backup-runtime.lock`.

## Restore drill (quarterly)

Do this on **staging** first (every quarter). Live disaster recovery is the same commands plus `BACKUP_ALLOW_LIVE_RESTORE=1`.

1. Pick an artifact stamp from `$BACKUP_TARGET/<shop>/staging/` (or copy a live artifact to the staging host).
2. `fyrst-cli shopware backup recover --from <stamp> --i-understand-this-restores-this-host`
3. Confirm storefront/admin, then rewrite `sales_channel_domain` if the dump still has live URLs. On staging, `SYNC_REWRITE_APP_URL` (or `SYNC_REWRITE_URL_MAP`) in `deploy/sync.env` runs `bin/console fyrst:sales-channel:rewrite-urls` after restore; it is refused on live. Payment/shipping webhooks still need a manual check.
4. Record the date on the ClickUp Secrets & checklist page.

Live DR (only when live is already broken):

```bash
BACKUP_ALLOW_LIVE_RESTORE=1 fyrst-cli shopware backup recover --from <stamp> \
  --i-understand-this-restores-this-host
```

That sets `SYNC_ALLOW_LIVE_RESTORE=1` for the inner apply (`fyrst-cli shopware sync apply`). Sync still refuses live without that override. Inner apply imports `db.sql.gz` / `db.sql` and restores bind-mount trees — it does not dump.

After a live restore, run `IMAGE_TAG=$(cat .deployed-tag) fyrst-cli shopware deploy release` only if the running image tag no longer matches the dump; usually the image is fine and only data was restored.

## Related

- [sync-runtime.md](sync-runtime.md) — clone live → staging; **not** retention backups
- [README.md](README.md) — VPS deploy, rollback, edge
- [edge/README.md](edge/README.md) — TLS before go-live
