# fyrst.dev — primary deploy: Docker Compose on a VPS
#
# Locked process: https://app.clickup.com/90151931897/docs/2kyqjkzt-915
# Image is built in CI from `docker/Dockerfile` (`shopware-cli project ci`). This host only pulls and runs it.
#
# CD/VPS stack lives here under `deploy/`. Shop-root `compose.yaml` is owned by
# `shopware-cli project create` (`shopware-cli project dev`) — not this recipe.

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
4. Create `.env.prod` (may be empty) so `deploy/compose.prod.yaml` can mount it.
5. Set `IMAGE` to the registry repository CI pushes (example: `ghcr.io/fyrst-dev/shop-name`).
6. `docker login` to that registry on the VPS (or use a credential helper / `~/.docker/config.json`).
7. Put a reverse proxy in front of `HTTP_PORT` (TLS). Do not expose MySQL.
8. Store the previous image tag for rollback (the release script writes `.deployed-tag` / `.previous-tag`).

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

   (via `docker compose -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml --profile setup run --rm --no-build setup`)
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
docker compose -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml ...
```

- `deploy/compose.yaml` — CD/VPS image-based stack
- `deploy/compose.prod.yaml` — production overrides
`deploy/vps-release.sh` sources shop-root `.env` then runs that command from `COMPOSE_DIR` (shop root).

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
