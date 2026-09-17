# fyrst/shopware-cd Flex recipe

Thin Flex metadata for Packagist package [`fyrst/shopware-cd`](https://github.com/fyrst-dev/shopware-cd). Overlay files (CI, CD Compose, edge, `.dockerignore`, `.env.example`) live in that package under `overlay/`. Flex `copy-from-package` maps `overlay/` onto the shop root. This recipe has no `root/` and no `copy-from-recipe`.

`manifest.json` keeps `bundles` + `env`. `post-install.txt` is the Flex toast only (not a shop file). `tests/` is not Flex-copied.

## Ownership

| File | Owner |
|---|---|
| `compose.yaml`, `.gitignore`, `.shopware-project.yml` (create’s default; `.yaml` also accepted — do not rename) | `shopware-cli project create` / the CLI — **not** this recipe |
| `docker/Dockerfile` | `shopware/docker` (required in the same `composer require`) |
| `.github/workflows/cd.yaml`, `.gitlab-ci.yaml`, `deploy/` (Compose + edge), `.dockerignore`, `.env.example` | package `overlay/` via Flex `copy-from-package`. Operators run [fyrst-cli](https://github.com/fyrst-dev/cli) 0.1.0+ (install on each VPS). Dump stays `shopware-cli`. Create / image build stay out of this recipe. |

**Local:** `shopware-cli project dev` and the CLI-managed shop-root `compose.yaml`.

Live Compose profiles: uncomment `COMPOSE_PROFILES=redis,worker,scheduler` in `.env`. Staging leaves profiles unset unless you intentionally need worker/scheduler.

**VPS/CD:** image-based stack under `deploy/`:

```bash
docker compose --env-file .env -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml
```

CI runs `fyrst-cli shopware deploy release` (existing `IMAGE` / `IMAGE_TAG` / `COMPOSE_DIR`). Rollback is `fyrst-cli shopware deploy rollback`.

Flex `env` may append a `###> fyrst/shopware-cd ###` block to shop-root `.env` (empty `SHOPWARE_SHOP_ID`, `SHOPWARE_DEPLOY_ENV=live`, `SHOPWARE_DATA_BASE=/var/lib/shopware/data`). It does not overwrite create’s whole `.env`. Then run `fyrst-cli shopware env init --shop-id <slug>` (see the copied `deploy/README.md`). That command always comments out create’s `COMPOSE_PROJECT_NAME=sw-shop-…` line (laptop and VPS same; it overrides Compose `name:`). It does not generate `APP_SECRET` (`shopware-cli project create` already writes it). Install fyrst-cli 0.1.0+ on each VPS.

VPS runtime DB + bind-mount pull (no object storage): `fyrst-cli shopware sync {capture|apply|pull}` — see `deploy/sync-runtime.md`. **Dump stays `shopware-cli project dump`.** **Sync is not a backup** — live backups are `fyrst-cli shopware backup {create|prune|recover}`. Compose source of truth is `SHOPWARE_SHOP_ID` + `SHOPWARE_DEPLOY_ENV` (project name `acme-live`, uploads under `/var/lib/shopware/data/${SHOPWARE_SHOP_ID}/${SHOPWARE_DEPLOY_ENV}`). `COMPOSE_PROJECT_NAME` / `SHOPWARE_DATA_ROOT` are optional script overrides. Flex does not delete it on `composer require`. Same-host tag-and-load: `PULL_POLICY=never` / `SKIP_PULL=1`.

Prod HTTP is loopback-only; host TLS is `deploy/edge/Caddyfile`. `web` healthcheck is `GET /api/_info/health-check` on `127.0.0.1:8000` inside the container.

Local `shopware-cli project dev` pull (rsync path remap, no DB): `fyrst-cli shopware sync local` (derives remote `/var/lib/shopware/data/${SHOPWARE_SHOP_ID}/live`). `--data all` is refused; use the default volume list.

Managed host deploy (`deploy/managed/`) is **planned / not implemented**. Compose/VPS is the only supported last mile.

After package overlay changes, shops run `composer update fyrst/shopware-cd` then `composer recipes:update fyrst/shopware-cd` and merge new `.env.example` keys. Flex `bundles` writes `Fyrst\ShopwareCd\FyrstShopwareCdBundle` into `config/bundles.php` (needed for `bin/console fyrst:sales-channel:rewrite-urls`).
