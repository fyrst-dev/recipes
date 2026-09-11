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
docker compose -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml
```

(`deploy/vps-release.sh` runs that from the shop root.)

VPS runtime DB + bind-mount pull (no object storage): `deploy/sync-runtime.sh` — see `deploy/sync-runtime.md`. Uploads live under `SHOPWARE_DATA_ROOT`.
