# VPS backup (not sync)

**`deploy/sync-runtime.sh` is not a backup.** Sync clones live → staging/playground/dev. It refuses to restore onto live. Live MySQL (`mysql_data` named volume) and bind mounts under the derived data root sit on the **same VPS disk** as the checkout. Disk loss or a bad restore-from-live onto the wrong host is not covered by sync.

This file is the **backup** path: timestamped artifacts on another disk or another host, with retention, checksums, and a restore drill.

Non-goals: WAL shipping / PITR, S3.

## What is copied

Same trees as sync `--data all`:

| Item | Mechanism |
| --- | --- |
| `db` | Logical SQL dump via `shopware-cli project dump` (same as sync: pinned `ghcr.io/shopware/shopware-cli:0.18.4` one-shot on the Compose network, or `DATABASE_URL`). Restore is still MySQL/MariaDB client import. |
| `media` `files` `thumbnail` `theme` `sitemap` | Bind-mount trees under `$SHOPWARE_DATA_BASE/$SHOPWARE_SHOP_ID/$SHOPWARE_DEPLOY_ENV` |

Layout on `BACKUP_TARGET`:

```text
$BACKUP_TARGET/$SHOPWARE_SHOP_ID/$SHOPWARE_DEPLOY_ENV/YYYYMMDDTHHMMSSZ/
  db.sql.gz
  data/media/ …
  MANIFEST.txt          # from sync snapshot
  BACKUP_MANIFEST.txt  # shop id, env, target
  SHA256SUMS
```

## One-time setup (live)

On the **live** VPS (unlike sync, which you configure on staging):

1. Copy `deploy/backup.env.example` → `deploy/backup.env` and `chmod 600 deploy/backup.env`.
2. Set `BACKUP_TARGET` to a **second disk** or an **SSH host** (not only a directory on the same root filesystem as `/var/lib/shopware`). Same-disk copies are better than nothing but do not survive disk loss.
3. `SHOPWARE_SHOP_ID` + `SHOPWARE_DEPLOY_ENV=live` in shop-root `.env` (same as Compose).
4. Shop-root `.env` still needs `IMAGE` (snapshot interpolates compose). First dump also needs to **pull** `ghcr.io/shopware/shopware-cli:0.18.4` (or `SYNC_SHOPWARE_CLI_IMAGE`). Dump flags (`SYNC_DUMP_CLEAN`, `SYNC_DUMP_ANONYMIZE`, …) are read from the environment / `deploy/sync.env` / this file.

Do not commit `deploy/backup.env`.

## Commands

```bash
# Preview (no dump). Allowed on live.
bash deploy/backup-runtime.sh backup --dry-run

# Nightly (live)
bash deploy/backup-runtime.sh backup

# Retention only
bash deploy/backup-runtime.sh prune

# Restore onto this host (staging drill — no live flag)
bash deploy/backup-runtime.sh restore --from 20260912T020000Z \
  --i-understand-this-restores-this-host
```

`backup` always prunes after a successful snapshot. `BACKUP_KEEP_DAYS` (default 14, `0` = keep forever) deletes artifact directories whose **timestamp name** `YYYYMMDDTHHMMSSZ` is older than that many days (UTC).

## Cron (live)

```cron
20 2 * * * cd /opt/shopware/acme-live && bash deploy/backup-runtime.sh backup
```

Overlapping runs are blocked with `flock` on `var/backup-runtime.lock`.

## Restore drill (quarterly)

Do this on **staging** first (every quarter). Live disaster recovery is the same commands plus `BACKUP_ALLOW_LIVE_RESTORE=1`.

1. Pick an artifact stamp from `$BACKUP_TARGET/<shop>/staging/` (or copy a live artifact to the staging host).
2. `bash deploy/backup-runtime.sh restore --from <stamp> --i-understand-this-restores-this-host`
3. Confirm storefront/admin, then rewrite `sales_channel_domain` if the dump still has live URLs. On staging, `SYNC_REWRITE_APP_URL` (or `SYNC_REWRITE_URL_MAP`) in `deploy/sync.env` runs `bin/console fyrst:sales-channel:rewrite-urls` after restore; it is refused on live. Payment/shipping webhooks still need a manual check.
4. Record the date on the ClickUp Secrets & checklist page.

Live DR (only when live is already broken):

```bash
BACKUP_ALLOW_LIVE_RESTORE=1 bash deploy/backup-runtime.sh restore --from <stamp> \
  --i-understand-this-restores-this-host
```

That sets `SYNC_ALLOW_LIVE_RESTORE=1` for `deploy/sync-runtime.sh restore` (sync still refuses live without that override). Restore reuses sync's dump/bind-mount restore helpers.

After a live restore, run `IMAGE_TAG=$(cat .deployed-tag) bash deploy/vps-release.sh` only if the running image tag no longer matches the dump; usually the image is fine and only data was restored.

## Related

- [sync-runtime.md](sync-runtime.md) — clone live → staging; **not** retention backups
- [README.md](README.md) — VPS deploy, rollback, edge
- [edge/README.md](edge/README.md) — TLS before go-live
