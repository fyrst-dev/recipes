# fyrst/shopware-cd Flex recipe

Overlays for Packagist package [`fyrst/shopware-cd`](https://github.com/fyrst-dev/shopware-cd). Flex copies from `1.0/root/` into the shop root.

## Ownership

| File | Owner |
|---|---|
| `compose.yaml`, `.gitignore`, `.shopware-project.yaml` | `shopware-cli project create` / the CLI — **not** this recipe |
| `docker/Dockerfile` | `shopware/docker` (required in the same `composer require`) |
| `.github/workflows/cd.yaml`, `.gitlab-ci.yaml`, `deploy/`, `.dockerignore`, `.env.example` | this recipe |

**Local:** `shopware-cli project dev` and the CLI-managed shop-root `compose.yaml`.

**VPS/CD:** image-based stack under `deploy/`:

```bash
docker compose --env-file .env -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml
```

(`deploy/vps-release.sh` runs that from the shop root.)

VPS runtime DB + bind-mount pull (no object storage): `deploy/sync-runtime.sh` — see `deploy/sync-runtime.md`. Compose source of truth is `SHOPWARE_SHOP_ID` + `SHOPWARE_DEPLOY_ENV` (project name `acme-live`, uploads under `/var/lib/shopware/data/${SHOPWARE_SHOP_ID}/${SHOPWARE_DEPLOY_ENV}`). `COMPOSE_PROJECT_NAME` / `SHOPWARE_DATA_ROOT` are optional script overrides.

Local `shopware-cli project dev` pull (rsync path remap, no DB): `deploy/sync-runtime-local.sh` (derives remote `/var/lib/shopware/data/${SHOPWARE_SHOP_ID}/live`).

After changes here, shops run `composer recipes:update fyrst/shopware-cd` and merge new `.env.example` keys.
