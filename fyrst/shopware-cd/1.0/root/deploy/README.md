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

- **web** — Shopware image (`ghcr.io/shopware/docker-base` + project artifact), port 8000
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
8. Put a reverse proxy in front of `HTTP_PORT` (TLS). Do not expose MySQL.
9. Store the previous image tag for rollback (the release script writes `.deployed-tag` / `.previous-tag`).

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
6. Optional `SMOKE_URL` check

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

```bash
export IMAGE_TAG=$(cat .previous-tag)
bash ./deploy/vps-release.sh
```

Keep the previous image physically on the host (`docker image prune` with care).

## Required CI secrets (Compose path)

See comments at the top of `.github/workflows/cd.yaml` and `.gitlab-ci.yaml`.

Typical: `SSH_PRIVATE_KEY`, `VPS_HOST`, `VPS_USER`, `VPS_PATH`, `SSH_KNOWN_HOSTS`.

## Runtime data sync

Pull **database + bind-mounted upload trees** (`media`, `files`, `thumbnail`, `theme`, `sitemap` under the derived data root) from another VPS onto this one (usually live → staging). SSH + `mysqldump`/`mariadb-dump` + **rsync of those host directories**. Object storage (S3 and similar) is out of scope. Runtime data stays out of git and out of the app image.

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
