# Planned / not implemented: managed container host

**Status: planned.** This path is **not implemented**. CI does not run a managed deploy job. Setting `DEPLOY_TARGET=managed` is **not** a supported switch — it does not deploy, and it must not skip the Compose/VPS job.

Same Shopware **image** as the Compose/VPS path remains the intended future contract (`shopware/docker`'s `docker/Dockerfile` only). Do **not** add a second Dockerfile.

Locked process: [Shopware Create & Continuous Deploy](https://app.clickup.com/90151931897/docs/2kyqjkzt-915)

## Why this page exists

A future managed host (PaaS-style / mittwald-style container runtime) would reuse the same image and `shopware-deployment-helper` flags. Until a real host is chosen and wired, treat Compose/VPS (`deploy/vps-release.sh`) as the **only** supported deploy path.

## What would stay the same (when implemented)

1. Build with `shopware-cli project ci` in `docker/Dockerfile` (from `shopware/docker`)
2. Push `:sha` / `:latest` / `:semver`
3. Run Deployment Helper as a one-shot/setup job against that image

## What would change (not built)

Only the **deploy job** (and maybe which registry you push to):

- Push to the host’s registry **or** let the host pull from yours
- Trigger their deploy API / CLI / UI instead of SSH + Compose
- Map runtime env (`APP_URL`, `DATABASE_URL`, `APP_SECRET`, `INSTALL_ADMIN_*`) in the host’s secret store

## CI

The former `deploy_managed` stub jobs in `.github/workflows/cd.yaml` and `.gitlab-ci.yaml` were removed (recipes #19). They always `exit 1` after pretending to be a deploy path. Do not re-add a failing stub.

`DEPLOY_TARGET` is reserved for a future implementation. It is ignored today. The Compose/VPS job is the supported last mile.

## What to fill in per host (when a real host exists)

- [ ] Registry URL the platform pulls from
- [ ] Deploy token / kubeconfig / host CLI credentials (CI secret)
- [ ] How to run the one-shot setup command with the **same** flags:

  ```bash
  vendor/bin/shopware-deployment-helper run \
    --skip-theme-compile \
    --skip-assets-install
  ```

- [ ] Health/smoke URL after rollout
- [ ] Rollback: redeploy the previous `:sha` tag (`deploy/vps-rollback.sh` on Compose)

## Keep identical across hosts (future)

- `docker/Dockerfile` (from `shopware/docker`) / `PHP_VERSION=8.3`
- `.shopware-project.yml` (create’s default; `.yaml` also accepted — owned by `shopware-cli project create` / the CLI, not this recipe)
- Image naming and tags
- Setup command (deployment helper + skip flags)
- Optional build-time secrets (`SHOPWARE_PACKAGES_TOKEN` only if the shop uses packages.shopware.com; Composer auth). Empty token is fine.
