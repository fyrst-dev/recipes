# fyrst/shopware-cd Flex recipe

Overlays for Packagist package [`fyrst/shopware-cd`](https://github.com/fyrst-dev/shopware-cd). Flex copies from `1.0/root/` into the shop root.

## Ownership

| File | Owner |
|---|---|
| `compose.yaml`, `.gitignore`, `.shopware-project.yml` (create’s default; `.yaml` also accepted — do not rename) | `shopware-cli project create` / the CLI — **not** this recipe |
| `docker/Dockerfile` | `shopware/docker` (required in the same `composer require`) |
| `.github/workflows/cd.yaml`, `.gitlab-ci.yaml`, `deploy/`, `.dockerignore`, `.env.example` | this recipe |

**Local:** `shopware-cli project dev` and the CLI-managed shop-root `compose.yaml`.

Live Compose profiles: uncomment `COMPOSE_PROFILES=redis,worker,scheduler` in `.env`. Staging leaves profiles unset unless you intentionally need worker/scheduler.

**VPS/CD:** image-based stack under `deploy/`:

```bash
docker compose --env-file .env -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml
```

(`deploy/vps-release.sh` / `deploy/vps-rollback.sh` run that from the shop root.)

Flex `env` may append a `###> fyrst/shopware-cd ###` block to shop-root `.env` (empty `SHOPWARE_SHOP_ID`, `SHOPWARE_DEPLOY_ENV=live`, `SHOPWARE_DATA_BASE=/var/lib/shopware/data`). It does not overwrite create’s whole `.env`. Then run `bash deploy/init-env.sh --shop-id <slug>` (see `deploy/README.md`).

VPS runtime DB + bind-mount pull (no object storage): `deploy/sync-runtime.sh` — see `deploy/sync-runtime.md`. **Sync is not a backup** — live backups are `deploy/backup-runtime.sh`. Compose source of truth is `SHOPWARE_SHOP_ID` + `SHOPWARE_DEPLOY_ENV` (project name `acme-live`, uploads under `/var/lib/shopware/data/${SHOPWARE_SHOP_ID}/${SHOPWARE_DEPLOY_ENV}`). `COMPOSE_PROJECT_NAME` / `SHOPWARE_DATA_ROOT` are optional script overrides. **VPS:** comment out create’s `COMPOSE_PROJECT_NAME=sw-shop-…` line (`bash deploy/init-env.sh --vps` or by hand; it overrides Compose `name:`). Same-host tag-and-load: `PULL_POLICY=never` / `SKIP_PULL=1`.

Prod HTTP is loopback-only; host TLS is `deploy/edge/Caddyfile`. `web` healthcheck is `GET /api/_info/health-check` on `127.0.0.1:8000` inside the container.

Local `shopware-cli project dev` pull (rsync path remap, no DB): `deploy/sync-runtime-local.sh` (derives remote `/var/lib/shopware/data/${SHOPWARE_SHOP_ID}/live`).

Managed host deploy (`deploy/managed/`) is **planned / not implemented**. Compose/VPS is the only supported last mile.

After changes here, shops run `composer recipes:update fyrst/shopware-cd` and merge new `.env.example` keys.
