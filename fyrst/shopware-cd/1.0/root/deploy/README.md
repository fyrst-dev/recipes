# fyrst.dev — primary deploy: Docker Compose on a VPS
#
# Locked process: https://app.clickup.com/90151931897/docs/2kyqjkzt-915
# Image is built in CI from `docker/Dockerfile` (`shopware-cli project ci`). This host only pulls and runs it.
#
# CD/VPS stack lives here under `deploy/`. Shop-root `compose.yaml` is owned by
# `shopware-cli project create` (`shopware-cli project dev`) — not this recipe.
#
# Naming (shop-root `.env`; same shop slug on live + staging + laptop):
#   SHOPWARE_SHOP_ID       stable slug (e.g. acme) — required
#   SHOPWARE_DEPLOY_ENV    live | staging | playground | dev — required
#   SHOPWARE_DATA_BASE     optional prefix (default /var/lib/shopware/data)
# Compose interpolates project name + bind mounts from shop id + env
# (three separate interpolations; nested ${A:-.../${B}} defaults do not expand).
# COMPOSE_PROJECT_NAME / SHOPWARE_DATA_ROOT are optional script/docs overrides
# (scripts derive them when unset; if set, scripts prefer them). Compose does
# not fail when those two are absent — do not set them empty.
# After recipe changes: `composer recipes:update fyrst/shopware-cd` then merge
# new keys from `.env.example` into each shop's `.env`.

## Model

- **web** — Shopware image (`ghcr.io/shopware/docker-base` + project artifact), port 8000 (prod: loopback only)
- **setup** — one-shot `shopware-deployment-helper` (profile `setup`)
- **mysql** — bundled in Compose, or delete the service and point `DATABASE_URL` at DBaaS. Prod overlay keeps `ports: []`.
- **redis** / **worker** / **scheduler** — optional Compose profiles
- **setup** — one-shot `shopware-deployment-helper` (profile `setup`)
- **mysql** — bundled in Compose, or delete the service and point `DATABASE_URL` at DBaaS
- **redis** / **worker** / **scheduler** — optional Compose profiles

## One-time VPS bootstrap

1. Install Docker Engine + Compose plugin. Do not install Shopware or PHP on the host.
2. Checkout this shop repo (read-only deploy key) to a path such as `/opt/shopware/<shop>`.
   That path is `VPS_PATH` in CI.
3. Copy `.env.example` → `.env` and fill runtime secrets. `chmod 600 .env`.
   Required source of truth:

   ```bash
   SHOPWARE_SHOP_ID=acme
   SHOPWARE_DEPLOY_ENV=live          # this host's role
   # optional: SHOPWARE_DATA_BASE=/var/lib/shopware/data
   ```

   Compose derives `acme-live` as the project name and
   `/var/lib/shopware/data/acme/live` as the bind-mount root. It does not
   require `COMPOSE_PROJECT_NAME` or `SHOPWARE_DATA_ROOT`. `deploy/vps-release.sh`
   and the sync scripts still derive those expanded strings when unset (and
   prefer them when set) for logs and tools.
4. Create `.env.prod` (may be empty) so `deploy/compose.prod.yaml` can mount it.
5. Set `IMAGE` to the registry repository CI pushes (example: `ghcr.io/fyrst-dev/shop-name`).
6. Create the runtime upload bind mounts (uid 82 = www-data in docker-base):

   ```bash
   # derived path — unique per shop + env
   DATA="${SHOPWARE_DATA_BASE:-/var/lib/shopware/data}/${SHOPWARE_SHOP_ID}/${SHOPWARE_DEPLOY_ENV}"
   mkdir -p "${DATA}"/{files,media,thumbnail,theme,sitemap}
   chown -R 82:82 "${DATA}"
   # e.g. /var/lib/shopware/data/acme/live/{files,media,thumbnail,theme,sitemap}
   ```

   `mysql_data` / `redis_data` stay named volumes (prefixed by the Compose
   project name from shop id + env).

7. `docker login` to that registry on the VPS (or use a credential helper / `~/.docker/config.json`).
8. Put **host Caddy** in front of loopback `HTTP_PORT` (TLS). See **[edge/README.md](edge/README.md)** and `deploy/edge/Caddyfile`. Do not expose MySQL (`compose.prod.yaml` keeps `ports: []`).
9. Store the previous image tag for rollback (the release script writes `.deployed-tag` / `.previous-tag`). Use `deploy/vps-rollback.sh` — do not re-run a failed tag via CI unless you mean to.
10. Copy `deploy/backup.env.example` → `deploy/backup.env` on **live** and enable nightly `deploy/backup-runtime.sh`. Sync is not a backup.

## Several shops / live+staging on the same VPS

`SHOPWARE_SHOP_ID` is the same slug everywhere for one shop. `SHOPWARE_DEPLOY_ENV` differs per stack. Checkout path (`VPS_PATH`) is independent of the data root.

| Stack | derived project name | derived data root |
| --- | --- | --- |
| acme live | `acme-live` | `/var/lib/shopware/data/acme/live` |
| acme staging | `acme-staging` | `/var/lib/shopware/data/acme/staging` |
| widgets live | `widgets-live` | `/var/lib/shopware/data/widgets/live` |

Named volumes become `acme-live_mysql_data`, `acme-staging_mysql_data`, … — unique because Compose prefixes them with the project name. Bind-mount trees do not overlap.

`deploy/compose.yaml` interpolates `name:` from shop id + env (no hardcoded `name: shopware`).

## CD sequence (what CI runs)

`deploy/vps-release.sh` (from the checkout at `VPS_PATH`):

1. Record the currently deployed tag as `.previous-tag`
2. `docker compose … pull` the new `:git-sha`
3. Start bundled `mysql` (if present) and optional profiles
4. Run setup **once**:

   ```bash
   vendor/bin/shopware-deployment-helper run \
     --skip-theme-compile \
     --skip-assets-install
   ```

   (via `docker compose --env-file .env -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml --profile setup run --rm --no-build setup`)
5. Recreate `web` with `--no-build`
6. Optional `SMOKE_URL` check. **Writes `.deployed-tag` only after success.**
7. On smoke failure: always prints
   `IMAGE_TAG=$(cat .previous-tag) bash deploy/vps-rollback.sh`
   and **auto-runs that rollback when `SHOPWARE_DEPLOY_ENV=live`** (default on). Staging/dev stay manual unless `ROLLBACK_ON_SMOKE_FAIL=1`. Release still exits 1 after a successful auto-rollback so CI does not treat the bad tag as live. First deploys with no `.previous-tag` cannot roll back.

Manual equivalent:

```bash
export IMAGE=ghcr.io/example-org/shop-name   # TODO
export IMAGE_TAG=<full-git-sha>

cd /opt/shopware/<shop>                      # TODO: VPS_PATH
git fetch --quiet origin
git checkout --quiet "$IMAGE_TAG"

bash ./deploy/vps-release.sh
```

Compose files used (from shop root; not the CLI-managed shop-root `compose.yaml`):

```bash
docker compose --env-file .env -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml ...
```

- `deploy/compose.yaml` — CD/VPS image-based stack
- `deploy/compose.prod.yaml` — production overrides
`deploy/vps-release.sh` sources shop-root `.env` (shop id + env required), derives `COMPOSE_PROJECT_NAME` / `SHOPWARE_DATA_ROOT` when unset for logs/tools, then runs that command from `COMPOSE_DIR` (shop root). Compose itself does not need those two expanded vars.

Local development uses `shopware-cli project create`'s shop-root `compose.yaml` with `shopware-cli project dev`. This recipe does not copy that file.

## Why skip theme/assets on deploy

`shopware-cli project ci` already compiled them into the image. Rebuilding on the VPS is an anti-pattern (time + drift).

## Fresh install vs update

The helper detects a fresh database vs an existing shop:

- **Fresh:** schema, admin user from `INSTALL_ADMIN_*`, sales channel from `APP_URL` / `SALES_CHANNEL_URL`, extensions
- **Update:** migrations when the Shopware version changed, extension sync, hooks

## Rollback

`deploy/vps-rollback.sh` reads `.previous-tag` (refuses if missing/empty), keeps `IMAGE` from env/`.env`, and runs the **same** compose stack and order as release: pull → mysql/redis → setup profile → recreate `web` → extra profiles. Pull + `--no-build` only. Optional `SMOKE_URL`. Writes `.deployed-tag` only after success.

```bash
# Always printed on smoke failure; this is the supported one-liner:
IMAGE_TAG=$(cat .previous-tag) bash deploy/vps-rollback.sh

# Preview (no docker)
bash ./deploy/vps-rollback.sh --dry-run
```

Manual drill (staging): release tag A → release tag B → rollback restores A (`cat .deployed-tag` is A). Keep the previous image on the host (`docker image prune` with care).

`ROLLBACK_ON_SMOKE_FAIL`: unset → **on for `live`, off otherwise**. Set `0`/`false` to force off on live; `1`/`true` to enable on staging.

## HTTP healthcheck

`web` is healthy only when `GET http://127.0.0.1:8000/api/_info/health-check` succeeds **inside the container** (Shopware Core, `auth_required=false`; the path Shopware documents for Docker `HEALTHCHECK`). That fails if Caddy/nginx/FrankenPHP on 8000 is down or PHP-FPM/FrankenPHP does not run the kernel. It does not use the Docker host network.

FPM/Caddy/nginx `shopware/docker-base` images install `curl`; FrankenPHP may not — the probe falls back to PHP streams. `compose.prod.yaml` uses `start_period: 120s` so a cold VPS after deployment-helper can still become healthy.

## Edge / TLS (Caddy)

Default prod publish is `127.0.0.1:${HTTP_PORT:-8000}:8000` (`HTTP_BIND` override). Copy-paste host Caddyfile: **[edge/Caddyfile](edge/Caddyfile)**. Multi-shop and ACME: **[edge/README.md](edge/README.md)**. Put edge in front **before go-live**.

## Off-host backups

See **[backup-runtime.md](backup-runtime.md)**. Cron on live:

```cron
20 2 * * * cd /opt/shopware/acme-live && bash deploy/backup-runtime.sh backup
```

Copy `deploy/backup.env.example` → `deploy/backup.env`. `BACKUP_TARGET` = second disk or SSH. `BACKUP_KEEP_DAYS` (default 14) is implemented. Quarterly restore drill: restore onto staging first; live DR needs `BACKUP_ALLOW_LIVE_RESTORE=1`.

## Required CI secrets (Compose path)

See comments at the top of `.github/workflows/cd.yaml` and `.gitlab-ci.yaml`.

Typical: `SSH_PRIVATE_KEY`, `VPS_HOST`, `VPS_USER`, `VPS_PATH`, `SSH_KNOWN_HOSTS`.

## Runtime data sync

**Sync is not a backup.** `deploy/sync-runtime.sh` pulls **database + bind-mounted upload trees** from another VPS onto this one (usually live → staging). It refuses `SHOPWARE_DEPLOY_ENV=live` as a consumer. Off-host backups with retention are **[backup-runtime.md](backup-runtime.md)** (`deploy/backup-runtime.sh`, cron on live).

When `SHOPWARE_DATA_ROOT` / `SYNC_DATA_ROOT` are unset, `deploy/sync-runtime.sh` derives

`$SHOPWARE_DATA_BASE/$SHOPWARE_SHOP_ID/$SHOPWARE_DEPLOY_ENV`

(`SHOPWARE_DATA_BASE` default `/var/lib/shopware/data`). `--from live` remote root is `$BASE/$SHOPWARE_SHOP_ID/live` (or `SYNC_SOURCE_ENV`) unless `SYNC_REMOTE_DATA_ROOT` is set. Missing `SHOPWARE_SHOP_ID` is refused.

`mysql_data` / `redis_data` stay named volumes and are not copied (use `--data db` for SQL).

`init-perm` still chowns the bind-mount points (uid 82).

See **[sync-runtime.md](sync-runtime.md)**. Copy `deploy/sync.env.example` → `deploy/sync.env`. Cron on the consumer:

```cron
15 2 * * * cd /opt/shopware/acme-staging && bash deploy/sync-runtime.sh sync --from live --data all
```

```bash
bash deploy/sync-runtime.sh sync --from live --data all --dry-run
```

Restore/sync refuse `SYNC_ENV=live` and `SHOPWARE_DEPLOY_ENV=live` (and a checkout directory named `live`).

## Local project dev pull (live → laptop)

`deploy/sync-runtime-local.sh` rsyncs the same VPS bind-mount trees into a **`shopware-cli project dev`** checkout. Destinations are project-tree paths (`./public/media/`, `./files/`, …), **not** `SHOPWARE_DATA_ROOT`. The database is **not** restored.

Reads `SHOPWARE_SHOP_ID` from local `.env`. Default remote root:

`/var/lib/shopware/data/${SHOPWARE_SHOP_ID}/live`

Override with `--remote-data-root` / `SYNC_REMOTE_DATA_ROOT` / `SYNC_SOURCE_ENV`. Requires `SHOPWARE_SHOP_ID` unless an explicit remote root is set.

Default SSH host alias is `live` (`--from` / `SYNC_SSH_HOST`). `--delete` is off by default (safer on a dirty local tree). A checkout directory named `live` prints a warning so this is not confused with `deploy/sync-runtime.sh`.

```bash
bash deploy/sync-runtime-local.sh --from live --data all --dry-run
bash deploy/sync-runtime-local.sh --from live --data media,files
shopware-cli project console cache:clear
```
