# fyrst/shopware-cd Flex recipe

Thin Flex metadata for Packagist package [`fyrst/shopware-cd`](https://github.com/fyrst-dev/shopware-cd). Overlay files (CI, CD Compose, edge, `.dockerignore`, `.env.example`) live in that package under `overlay/`. Flex `copy-from-package` maps `overlay/` onto the shop root. This recipe has no `root/` and no `copy-from-recipe`.

`manifest.json` keeps `bundles` + `env`. `post-install.txt` is the Flex toast only (not a shop file). `tests/` is not Flex-copied.

## Ownership

| File | Owner |
|---|---|
| `compose.yaml`, `.gitignore`, `.shopware-project.yml` (create’s default; `.yaml` also accepted — do not rename) | `shopware-cli project create` / the CLI — **not** this recipe |
| `compose.override.yaml` | `fyrst-cli shopware env init` sets `name: <shop-id>-<env>` so `shopware-cli project dev` uses that project name (not the folder basename). Typically gitignored; this recipe does not copy it. |
| `docker/Dockerfile` | `shopware/docker` (required in the same `composer require`) |
| `.github/workflows/cd.yaml`, `.gitlab-ci.yaml`, `deploy/` (Compose + edge), `.dockerignore`, `.env.example` | package `overlay/` via Flex `copy-from-package`. Operators run [fyrst-cli](https://github.com/fyrst-dev/cli) 0.1.0+ (install on each VPS). Dump stays `shopware-cli`. Create / image build stay out of this recipe. |

**Local:** `shopware-cli project dev` and the CLI-managed shop-root `compose.yaml`.

Live Compose profiles: uncomment `COMPOSE_PROFILES=redis,worker,scheduler` in `.env`. Staging leaves profiles unset unless you intentionally need worker/scheduler.

**VPS/CD:** image-based stack under `deploy/`. Naming SoT is `deploy/compose.yaml` `name: ${SHOPWARE_SHOP_ID}-${SHOPWARE_DEPLOY_ENV}` with host env files loaded. Raw operator Compose must use the same `--env-file` flags as fyrst-cli (not only `.env`). Omit `--env-file .env.prod` when that file is absent.

```bash
docker compose --env-file .env --env-file .env.local --env-file .env.prod -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml
```

CI runs `fyrst-cli shopware deploy release` (existing `IMAGE` / `IMAGE_TAG` / `COMPOSE_DIR`). Rollback is `fyrst-cli shopware deploy rollback`. Post-deploy probe: default is `APP_URL` (trailing slash stripped) + `/api/_info/health-check` (same path as the Compose `web` healthcheck). Override with `DEPLOY_HEALTH_URL` (full URL as-is, e.g. loopback). Live requires a resolvable probe URL unless `--allow-no-deploy-health` / `ALLOW_NO_DEPLOY_HEALTH=1`. Non-live: the probe is optional when no URL can be resolved. Do not use `SMOKE_URL`; removed. Auto-rollback still uses `ROLLBACK_ON_SMOKE_FAIL`.

Flex `env` may append a `###> fyrst/shopware-cd ###` block to shop-root `.env` (empty `SHOPWARE_SHOP_ID`, `SHOPWARE_DATA_BASE=/var/lib/shopware/data`). It does not put `SHOPWARE_DEPLOY_ENV` in that shared block (host `.env.local` owns deploy env and `COMPOSE_PROJECT_NAME`) and does not overwrite create’s whole `.env`. Then run `fyrst-cli shopware env init --shop-id <slug>` (see the copied `deploy/README.md`). That command always comments out create’s `COMPOSE_PROJECT_NAME=sw-shop-…` in committed `.env` (it overrides Compose `name:`). It does not write `COMPOSE_PROJECT_NAME` or a real `SHOPWARE_DEPLOY_ENV` into committed `.env`. It writes `SHOPWARE_DEPLOY_ENV` and `COMPOSE_PROJECT_NAME=<shop-id>-<env>` into gitignored `.env.local` (local `acme-dev`, VPS `acme-live` — same pattern, not the folder basename and not `shopware-<shop-id>`) and sets `compose.override.yaml` `name:` so `shopware-cli project dev` sees that project name. VPS Compose naming SoT is `deploy/compose.yaml` `name: ${SHOPWARE_SHOP_ID}-${SHOPWARE_DEPLOY_ENV}` with `--env-file .env` then `--env-file .env.local` then `--env-file .env.prod` (if present); fyrst-cli passes those same `--env-file` flags. It does not generate `APP_SECRET` (`shopware-cli project create` already writes it). Install fyrst-cli 0.1.0+ on each VPS.

VPS runtime DB + bind-mount pull (no object storage): `fyrst-cli shopware sync {capture|apply|pull}` — see `deploy/sync-runtime.md`. **Dump stays `shopware-cli project dump`.** **Sync is not a backup** — live backups are `fyrst-cli shopware backup {create|prune|recover}`. Shared committed `.env` holds `SHOPWARE_SHOP_ID` (+ optional `SHOPWARE_DATA_BASE`). Host `.env.local` holds `SHOPWARE_DEPLOY_ENV` and `COMPOSE_PROJECT_NAME=<shop-id>-<env>` (project name `acme-live` / `acme-dev`, uploads under `/var/lib/shopware/data/${SHOPWARE_SHOP_ID}/${SHOPWARE_DEPLOY_ENV}`). `SHOPWARE_DATA_ROOT` is an optional script override. Flex does not delete it on `composer require` (create’s `COMPOSE_PROJECT_NAME=sw-shop-…` stays until env init). Same-host tag-and-load: `PULL_POLICY=never` / `SKIP_PULL=1`.

Prod HTTP is loopback-only; host TLS is `deploy/edge/Caddyfile`. `web` healthcheck is `GET /api/_info/health-check` on `127.0.0.1:8000` inside the container. After `deploy release` / `rollback`, fyrst-cli probes that same path on `APP_URL` unless `DEPLOY_HEALTH_URL` is set. Live requires a resolvable URL (`--allow-no-deploy-health` / `ALLOW_NO_DEPLOY_HEALTH=1` is the escape hatch). Do not use `SMOKE_URL`; removed. Auto-rollback still uses `ROLLBACK_ON_SMOKE_FAIL`.

Local `shopware-cli project dev` pull (rsync path remap, no DB): `fyrst-cli shopware sync local` (derives remote `/var/lib/shopware/data/${SHOPWARE_SHOP_ID}/live`). `--data all` is refused; use the default volume list.

Managed host deploy (`deploy/managed/`) is **planned / not implemented**. Compose/VPS is the only supported last mile.

After package overlay changes, shops run `composer update fyrst/shopware-cd` then `composer recipes:update fyrst/shopware-cd` and merge new `.env.example` keys. Flex `bundles` writes `Fyrst\ShopwareCd\FyrstShopwareCdBundle` into `config/bundles.php` (needed for `bin/console fyrst:sales-channel:rewrite-urls`).
