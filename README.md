# fyrst Flex recipes

Private, fyrst-controlled [Symfony Flex](https://symfony.com/doc/current/setup/flex.html) endpoint for fyrst packages (starting with `fyrst/shopware-cd`).

This is the Shopware-style recipes repo for fyrst: vendor directories live at the repository root (`fyrst/shopware-cd/1.0/`), and a GitHub Action compiles them into a Flex index. Shops can consume recipes here **without waiting** on [symfony/recipes-contrib](https://github.com/symfony/recipes-contrib).

[symfony/recipes-contrib#2049](https://github.com/symfony/recipes-contrib/pull/2049) may still exist as the upstream contrib PR. This repository is the fyrst-owned path: we can ship and iterate independently of that review queue.

Same idea as [shopware/recipes](https://github.com/shopware/recipes).

## Endpoint URL

After the Flex compiler workflow has run on `main`:

```
https://raw.githubusercontent.com/fyrst-dev/recipes/flex/main/index.json
```

The workflow writes the compiled index to the `flex/main` branch (force-pushed on every update). That URL is a stub `{}` until the first successful compiler run, then it lists `fyrst/shopware-cd` and recipe payloads.

## Configure a shop (Composer)

Prepend this endpoint **before** Shopware recipes and `flex://defaults` so fyrst recipes win:

```json
{
    "extra": {
        "symfony": {
            "allow-contrib": true,
            "endpoint": [
                "https://raw.githubusercontent.com/fyrst-dev/recipes/flex/main/index.json",
                "https://raw.githubusercontent.com/shopware/recipes/flex/main/index.json",
                "flex://defaults"
            ]
        }
    }
}
```

Equivalent CLI:

```bash
composer config extra.symfony.allow-contrib true
composer config --json extra.symfony.endpoint '["https://raw.githubusercontent.com/fyrst-dev/recipes/flex/main/index.json","https://raw.githubusercontent.com/shopware/recipes/flex/main/index.json","flex://defaults"]'
```

## Install

```bash
shopware-cli project create <shop>
cd <shop>
# configure endpoint as above (composer config / composer.json)
composer require shopware/docker shopware/deployment-helper fyrst/shopware-cd
```

`shopware/docker` is required in that same command: it copies `docker/Dockerfile`, which CI and CD Compose default to. This recipe does not ship a root Dockerfile. A missing `docker/Dockerfile` means `shopware/docker` was skipped.

`shopware-cli project create` owns `compose.yaml`, `.gitignore`, and `.shopware-project.yml` (create’s default; `.yaml` is also accepted — do not rename). This recipe does **not** copy them.

- **Local:** `shopware-cli project dev` and the CLI-managed shop-root `compose.yaml`. Live → laptop uploads: `deploy/sync-runtime-local.sh`.
- **VPS/CD:** files under `deploy/` (`deploy/compose.yaml`, `deploy/compose.prod.yaml`, `deploy/compose.vps.yaml`, `deploy/vps-release.sh`, `deploy/vps-rollback.sh`, `deploy/backup-runtime.sh`, `deploy/sync-runtime.sh`, `deploy/edge/`).

Flex copies CI, `deploy/` (including CD Compose), `.dockerignore`, and `.env.example` into the shop root. Copy `.env.example` → `.env` yourself (Flex never writes `.env`). Commit the copied files; `vendor/` stays gitignored.

## Update recipes

1. Change files under `fyrst/<package>/<version>/` in this repo.
2. Push (or merge) to `main`.
3. The **Update Flex endpoint** workflow rebuilds `flex/main` (`index.json`).
4. In each shop:

```bash
composer recipes:update fyrst/shopware-cd
```

## GitHub Actions (`flex/main`)

`.github/workflows/flex-update.yml` calls [symfony/recipes `callable-flex-update.yml`](https://github.com/symfony/recipes/blob/main/.github/workflows/callable-flex-update.yml) with `contents: write` so `GITHUB_TOKEN` can force-push the `flex/main` branch.

- The callable workflow runs `git switch flex/main`. That branch **must already exist** (orphan branch with a stub `index.json`). Without it, the first run fails with `fatal: invalid reference: flex/main`.
- The **first push to `main` that includes this workflow** must run **Update Flex endpoint**. Until that job succeeds, shops should not rely on the endpoint.
- If GitHub Actions is **disabled** for the `fyrst-dev` org or this repository, the compiler never runs and shops cannot load recipes. Enable Actions (org **Settings → Actions → General**, and the same at repo level), then re-run the workflow or push an empty commit on `main`.
- Repo **Settings → Actions → General → Workflow permissions** should allow the job’s `permissions: contents: write` (do not force a read-only token that cannot push `flex/main`).
- Closed pull requests are cleaned up by `.github/workflows/flex-cleanup.yml` (drops the temporary `flex/pull-<n>` testing ref).

## Layout

| Path | Role |
|---|---|
| `fyrst/shopware-cd/1.0/` | Current Flex recipe for Packagist package `fyrst/shopware-cd` (overlays live only here; Packagist package repo is https://github.com/fyrst-dev/shopware-cd). Ships CI, `deploy/` (CD Compose), `.dockerignore`, `.env.example`. Does not copy `compose.yaml`, `.gitignore`, or `.shopware-project.yml` / `.yaml` (`shopware-cli project create` / CLI). |
| `.github/workflows/flex-update.yml` | Compiles recipes → `flex/main` |
| `.github/workflows/flex-cleanup.yml` | Deletes Flex PR test refs |

`manifest.json` has no `aliases`. Recipe YAML uses `.yaml` names and 4-space indent.
