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
# (fyrst-cli derives them when unset; if set, it prefers them). Compose does
# not fail when those two are absent — do not set them empty.
#
# WARNING: `shopware-cli project create` writes `COMPOSE_PROJECT_NAME=sw-shop-…`
# into shop-root `.env` for local `project dev`. That env var **overrides**
# Compose `name:` (`${SHOPWARE_SHOP_ID}-${SHOPWARE_DEPLOY_ENV}`). On the VPS,
# **comment out** that line: `fyrst-cli shopware env init --vps` (or by hand).
# Flex does not delete it on `composer require` (create owns the local flow).
# `fyrst-cli shopware deploy release` warns when the value does not match shop id + deploy env.
# After recipe changes: `composer recipes:update fyrst/shopware-cd` then
# `fyrst-cli shopware env init` (or merge new keys from `.env.example` by hand).
# Install fyrst-cli 0.1.0+ on each VPS. Dump stays shopware-cli.

## fyrst-cli (required on each VPS / laptop)

Install [fyrst-cli](https://github.com/fyrst-dev/cli) 0.1.0+ once per host:

```bash
curl -fsSL https://raw.githubusercontent.com/fyrst-dev/cli/main/scripts/install.sh | bash
# pin: FYRST_CLI_VERSION=0.1.0 curl -fsSL … | bash
```

CI runs `fyrst-cli shopware deploy release` (existing `IMAGE` / `IMAGE_TAG` /
`COMPOSE_DIR`). Cron and operators use the same lifecycle verbs.
**Dump stays `shopware-cli project dump`.** fyrst-cli never dumps.

| Command | Role |
| --- | --- |
| `fyrst-cli shopware env init` | Finish shop-root `.env` after create + Flex |
| `fyrst-cli shopware deploy release` | Pull image, recreate the VPS stack |
| `fyrst-cli shopware deploy rollback` | Re-deploy `IMAGE` from `.previous-tag` |
| `fyrst-cli shopware sync capture` | Copy bind-mount trees into a workdir |
| `fyrst-cli shopware sync apply` | Apply that workdir onto this host |
| `fyrst-cli shopware sync pull` | Consumer cron: rsync `--from` + import existing dump |
| `fyrst-cli shopware sync local` | VPS → laptop project-dev (never DB; `--data all` refused) |
| `fyrst-cli shopware backup create` | Off-host backup (live allowed) |
| `fyrst-cli shopware backup prune` | Stamp-based retention |
| `fyrst-cli shopware backup recover` | Disaster recovery onto this host |

Image build stays in CI. `shopware-cli project create` stays create. Compose
templates under `deploy/` stay in this recipe.

## Model

- **web** — Shopware image (`ghcr.io/shopware/docker-base` + project artifact), port 8000 (prod: loopback only)
- **setup** — one-shot `shopware-deployment-helper` (profile `setup`)
- **mysql** — bundled in Compose, or delete the service and point `DATABASE_URL` at DBaaS. Prod overlay keeps `ports: []`.
- **redis** / **worker** / **scheduler** — Compose profiles. **Live recommendation:** `COMPOSE_PROFILES=redis,worker,scheduler` (uncomment in `.env`). Staging leaves this unset unless you intentionally need async/scheduled tasks. `fyrst-cli shopware deploy release` warns on live when the variable is empty; it does **not** auto-enable profiles.

## Shop-root `.env` after create (Flex + `fyrst-cli shopware env init`)

`shopware-cli project create` writes `.env`. Flex may append a marked block
(safe defaults only — empty shop id, no secrets):

```bash
###> fyrst/shopware-cd ###
SHOPWARE_SHOP_ID=
SHOPWARE_DEPLOY_ENV=live
SHOPWARE_DATA_BASE=/var/lib/shopware/data
###< fyrst/shopware-cd ###
```

Finish shop-specific values **without** replacing the whole file:

```bash
# laptop / after composer require
fyrst-cli shopware env init --shop-id acme

# VPS: set identity, optional IMAGE, comment out create's COMPOSE_PROJECT_NAME
fyrst-cli shopware env init --shop-id acme --env live --vps --image ghcr.io/fyrst-dev/shop-name

# optional: APP_SECRET only if empty
fyrst-cli shopware env init --shop-id acme --generate-app-secret

# preview
fyrst-cli shopware env init --shop-id acme --vps --dry-run
```

`--shop-id` is required unless `SHOPWARE_SHOP_ID` is already non-empty.
`--env` is `live` | `staging` | `playground` | `dev` (default `live` when
unset/empty; an existing non-empty value is kept). The command copies
`.env.example` → `.env` when `.env` is missing, then merges **missing** keys
from `.env.example` without clobbering existing non-empty values. It does
**not** invent `MYSQL_*` passwords or `APP_URL`.

## One-time VPS bootstrap

1. Install Docker Engine + Compose plugin. Do not install Shopware or PHP on the host.
   Install **fyrst-cli 0.1.0+** (`scripts/install.sh` above).
2. Checkout this shop repo (read-only deploy key) to a path such as `/opt/shopware/<shop>`.
   That path is `VPS_PATH` in CI.
3. Finish `.env` (Flex may already have appended SoT keys). `chmod 600 .env`.

   ```bash
   fyrst-cli shopware env init --shop-id acme --env live --vps --image ghcr.io/fyrst-dev/shop-name
   # equivalent keys:
   # SHOPWARE_SHOP_ID=acme
   # SHOPWARE_DEPLOY_ENV=live          # this host's role
   # optional: SHOPWARE_DATA_BASE=/var/lib/shopware/data
   ```

   Compose derives `acme-live` as the project name and
   `/var/lib/shopware/data/acme/live` as the bind-mount root. It does not
   require `COMPOSE_PROJECT_NAME` or `SHOPWARE_DATA_ROOT`. fyrst-cli still
   derives those expanded strings when unset (and prefers them when set)
   for logs and tools.

   **Do not copy create’s `COMPOSE_PROJECT_NAME=sw-shop-…` onto the VPS.**
   That line overrides Compose `name:`. Comment it out with
   `fyrst-cli shopware env init --vps` (or by hand). Local `shopware-cli project dev`
   can keep it; Flex does not delete it on `composer require` (create owns
   the local flow).
4. Create `.env.prod` (may be empty) so `deploy/compose.prod.yaml` can mount it.
5. Set `IMAGE` to the registry repository CI pushes (example: `ghcr.io/fyrst-dev/shop-name`)
   (`--image` on `env init`, or by hand).
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
9. Store the previous image tag for rollback (release writes `.deployed-tag` / `.previous-tag`). Use `fyrst-cli shopware deploy rollback` — do not re-run a failed tag via CI unless you mean to.
10. Copy `deploy/backup.env.example` → `deploy/backup.env` on **live** and enable nightly `fyrst-cli shopware backup create`. Sync is not a backup.
11. On **live**, uncomment `COMPOSE_PROFILES=redis,worker,scheduler` in `.env` (worker + scheduler; include redis if you use it). Staging should not inherit that unless documented.

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

`fyrst-cli shopware deploy release` (from the checkout at `VPS_PATH`):

1. Record the currently deployed tag as `.previous-tag`
2. `docker compose … pull` the new `:git-sha` (skip with `SKIP_PULL=1` / `PULL_POLICY=never` / `--skip-pull`)
3. Start bundled `mysql` (if present) and optional profiles
4. Run setup **once**:

   ```bash
   vendor/bin/shopware-deployment-helper run \
     --skip-theme-compile \
     --skip-assets-install
   ```

   (via `docker compose --env-file .env -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml --profile setup run --rm --pull never setup`)
5. Recreate `web` with `--no-build`
6. Optional `SMOKE_URL` check. **Writes `.deployed-tag` only after success.**
7. On smoke failure: always prints
   `IMAGE_TAG=$(cat .previous-tag) fyrst-cli shopware deploy rollback`
   and **auto-runs that rollback when `SHOPWARE_DEPLOY_ENV=live`** (default on). Staging/dev stay manual unless `ROLLBACK_ON_SMOKE_FAIL=1`. Release still exits 1 after a successful auto-rollback so CI does not treat the bad tag as live. First deploys with no `.previous-tag` cannot roll back.

Manual equivalent:

```bash
export IMAGE=ghcr.io/example-org/shop-name   # TODO
export IMAGE_TAG=<full-git-sha>

cd /opt/shopware/<shop>                      # TODO: VPS_PATH
git fetch --quiet origin
git checkout --quiet "$IMAGE_TAG"

fyrst-cli shopware deploy release
```

Compose files used (from shop root; not the CLI-managed shop-root `compose.yaml`):

```bash
docker compose --env-file .env -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml ...
```

- `deploy/compose.yaml` — CD/VPS image-based stack
- `deploy/compose.prod.yaml` — production overrides
- `deploy/compose.vps.yaml` — `pull_policy: ${PULL_POLICY:-always}` (CI/VPS default). Same-host tag-and-load / air-gap: `PULL_POLICY=never` and `SKIP_PULL=1` (or `fyrst-cli shopware deploy release --skip-pull`) so Compose does not pull a tag that was never pushed.
`fyrst-cli shopware deploy release` loads shop-root `.env` (shop id + env required), derives `COMPOSE_PROJECT_NAME` / `SHOPWARE_DATA_ROOT` when unset for logs/tools, then runs that command from `COMPOSE_DIR` (shop root). Compose itself does not need those two expanded vars.

Local development uses `shopware-cli project create`'s shop-root `compose.yaml` with `shopware-cli project dev`. This recipe does not copy that file. Create writes `.shopware-project.yml` (fine as-is; shopware-cli also accepts `.yaml` — do not rename).

## Why skip theme/assets on deploy

`shopware-cli project ci` already compiled them into the image. Rebuilding on the VPS is an anti-pattern (time + drift).

## Fresh install vs update

The helper detects a fresh database vs an existing shop:

- **Fresh:** schema, admin user from `INSTALL_ADMIN_*`, sales channel from `APP_URL` / `SALES_CHANNEL_URL`, extensions
- **Update:** migrations when the Shopware version changed, extension sync, hooks

## Rollback

`fyrst-cli shopware deploy rollback` reads `.previous-tag` (refuses if missing/empty), keeps `IMAGE` from env/`.env`, and runs the **same** compose stack and order as release: pull (unless skip) → mysql/redis → setup profile → recreate `web` → extra profiles. `compose run` uses `--pull never` (Compose v5 dropped `--no-build` from the run subcommand). `up` uses `--no-build`. Optional `SMOKE_URL`. Writes `.deployed-tag` only after success.

```bash
# Always printed on smoke failure; this is the supported one-liner:
IMAGE_TAG=$(cat .previous-tag) fyrst-cli shopware deploy rollback

# Preview (no docker)
fyrst-cli shopware deploy rollback --dry-run
```

Manual drill (staging): release tag A → release tag B → rollback restores A (`cat .deployed-tag` is A). Keep the previous image on the host (`docker image prune` with care).

`ROLLBACK_ON_SMOKE_FAIL`: unset → **on for `live`, off otherwise**. Set `0`/`false` to force off on live; `1`/`true` to enable on staging.

## HTTP healthcheck

`web` is healthy only when `GET http://127.0.0.1:8000/api/_info/health-check` succeeds **inside the container** (Shopware Core, `auth_required=false`; the path Shopware documents for Docker `HEALTHCHECK`). That fails if Caddy/nginx/FrankenPHP on 8000 is down or PHP-FPM/FrankenPHP does not run the kernel. It does not use the Docker host network.

FPM/Caddy/nginx `shopware/docker-base` images install `curl`; FrankenPHP may not — the probe falls back to PHP streams. `compose.prod.yaml` uses `start_period: 120s` so a cold VPS after deployment-helper can still become healthy.

## Edge / TLS (Caddy)

Default prod publish is `127.0.0.1:${HTTP_PORT:-8000}:8000` (`HTTP_BIND` override). `compose.prod.yaml` uses `ports: !override` so Compose does **not** keep the base `0.0.0.0` mapping from `compose.yaml`. Copy-paste host Caddyfile: **[edge/Caddyfile](edge/Caddyfile)**. Multi-shop and ACME: **[edge/README.md](edge/README.md)**. Put edge in front **before go-live**.

## Off-host backups

See **[backup-runtime.md](backup-runtime.md)**. Cron on live:

```cron
20 2 * * * cd /opt/shopware/acme-live && fyrst-cli shopware backup create
```

Copy `deploy/backup.env.example` → `deploy/backup.env`. `BACKUP_TARGET` = second disk or SSH. `BACKUP_KEEP_DAYS` (default 14) is implemented. Quarterly restore drill: restore onto staging first; live DR needs `BACKUP_ALLOW_LIVE_RESTORE=1`.

## Managed host (planned)

`deploy/managed/` is **planned / not implemented**. CI has no managed deploy job. Compose/VPS is the only supported last mile. See **[managed/README.md](managed/README.md)**.

## CI secrets (Compose path)

See comments at the top of `.github/workflows/cd.yaml` and `.gitlab-ci.yaml`.

Typical for deploy: `SSH_PRIVATE_KEY`, `VPS_HOST`, `VPS_USER`, `VPS_PATH`, `SSH_KNOWN_HOSTS`.

`SHOPWARE_PACKAGES_TOKEN` is optional — set it only if the shop uses packages.shopware.com. Empty is fine.

## Runtime data sync

**Sync is not a backup.** `fyrst-cli shopware sync pull` pulls **database + bind-mounted upload trees** from another VPS onto this one (usually live → staging). It refuses `SHOPWARE_DEPLOY_ENV=live` as a consumer. Off-host backups with retention are **[backup-runtime.md](backup-runtime.md)** (`fyrst-cli shopware backup create`, cron on live).

DB snapshots use **`shopware-cli project dump`** run by the operator (fyrst-cli never dumps). Place `db.sql.gz` in `--snapshot-dir` or set `BACKUP_DB_DUMP`. Restore is `fyrst-cli shopware db import` (MySQL/MariaDB client). See **[sync-runtime.md](sync-runtime.md)**.

When `SHOPWARE_DATA_ROOT` / `SYNC_DATA_ROOT` are unset, fyrst-cli derives

`$SHOPWARE_DATA_BASE/$SHOPWARE_SHOP_ID/$SHOPWARE_DEPLOY_ENV`

(`SHOPWARE_DATA_BASE` default `/var/lib/shopware/data`). `--from live` remote root is `$BASE/$SHOPWARE_SHOP_ID/live` (or `SYNC_SOURCE_ENV`) unless `SYNC_REMOTE_DATA_ROOT` is set. Missing `SHOPWARE_SHOP_ID` is refused.

`mysql_data` / `redis_data` stay named volumes and are not copied (use `--data db` for SQL).

`init-perm` still chowns the bind-mount points (uid 82).

See **[sync-runtime.md](sync-runtime.md)**. Copy `deploy/sync.env.example` → `deploy/sync.env`. Cron on the consumer:

```cron
15 2 * * * cd /opt/shopware/acme-staging && fyrst-cli shopware sync pull --from live --data all
```

```bash
fyrst-cli shopware sync pull --from live --data all --dry-run
```

Restore/sync refuse `SYNC_ENV=live` and `SHOPWARE_DEPLOY_ENV=live` (and a checkout directory named `live`).

Opt-in sales-channel domain rewrite after a DB restore: set `SYNC_REWRITE_APP_URL=https://staging.example.com` (or `SYNC_REWRITE_URL_MAP`) on the consumer. Default is off. Sync then runs `bin/console fyrst:sales-channel:rewrite-urls` (shops need `composer update fyrst/shopware-cd`). Rewrite is **impossible on live**. Payment/shipping webhooks still need a manual review. See **[sync-runtime.md](sync-runtime.md)**.

## Local project dev pull (live → laptop)

`fyrst-cli shopware sync local` rsyncs the same VPS bind-mount trees into a **`shopware-cli project dev`** checkout. Destinations are project-tree paths (`./public/media/`, `./files/`, …), **not** `SHOPWARE_DATA_ROOT`. The database is **not** restored. `--data all` is refused (on `sync pull` / `backup create`, `all` includes db). Use the default volume list or `--data media,files`.

Reads `SHOPWARE_SHOP_ID` from local `.env`. Default remote root:

`/var/lib/shopware/data/${SHOPWARE_SHOP_ID}/live`

Override with `--remote-data-root` / `SYNC_REMOTE_DATA_ROOT` / `SYNC_SOURCE_ENV`. Requires `SHOPWARE_SHOP_ID` unless an explicit remote root is set.

Default SSH host alias is `live` (`--from` / `SYNC_SSH_HOST`). `--delete` is off by default (safer on a dirty local tree). A checkout directory named `live` prints a warning so this is not confused with `fyrst-cli shopware sync pull`.

```bash
fyrst-cli shopware sync local --from live --dry-run
fyrst-cli shopware sync local --from live --data media,files
shopware-cli project console cache:clear
```
