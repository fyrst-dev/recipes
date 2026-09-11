#!/usr/bin/env bash
# Run on the VPS (or via SSH from CI) after the image has been pushed.
# Never builds the image and never compiles themes/assets.
#
# Required env:
#   IMAGE                  registry/repo (e.g. ghcr.io/fyrst-dev/shop-name) — no real defaults
#   IMAGE_TAG              full git SHA (or a rollback tag)
#   SHOPWARE_SHOP_ID       stable shop slug (same on live + staging + laptop)
#   SHOPWARE_DEPLOY_ENV    live|staging|playground|dev
# Optional:
#   COMPOSE_DIR            shop checkout (default: repository root next to deploy/)
#   COMPOSE_PROFILES       comma-separated: redis,worker,scheduler  (never include "setup")
#   SMOKE_URL              HTTP URL to probe after up (e.g. http://127.0.0.1:8000)
#   COMPOSE_PROJECT_NAME   unique on this Docker host; default ${SHOPWARE_SHOP_ID}-${SHOPWARE_DEPLOY_ENV}
#   SHOPWARE_DATA_ROOT     bind-mount root; default /var/lib/shopware/data/${SHOPWARE_SHOP_ID}/${SHOPWARE_DEPLOY_ENV}
#   SHOPWARE_DATA_BASE     prefix helper (default /var/lib/shopware/data)
#
# CI-exported IMAGE / IMAGE_TAG always win over .env (which often has IMAGE_TAG=latest).
#
# Compose files (always invoked from shop root COMPOSE_DIR):
#   docker compose -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml

set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$COMPOSE_DIR"

CI_IMAGE="${IMAGE:-}"
CI_IMAGE_TAG="${IMAGE_TAG:-}"
CI_SMOKE_URL="${SMOKE_URL:-}"
CI_PROFILES="${COMPOSE_PROFILES:-}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
if [[ -f .env.prod ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env.prod
  set +a
fi

IMAGE="${CI_IMAGE:-${IMAGE:-}}"
IMAGE_TAG="${CI_IMAGE_TAG:-${IMAGE_TAG:-}}"
SMOKE_URL="${CI_SMOKE_URL:-${SMOKE_URL:-}}"
COMPOSE_PROFILES="${CI_PROFILES:-${COMPOSE_PROFILES:-}}"

: "${IMAGE:?Set IMAGE to the registry repository}"
: "${IMAGE_TAG:?Set IMAGE_TAG to the git SHA (or previous tag for rollback)}"
: "${SHOPWARE_SHOP_ID:?Set SHOPWARE_SHOP_ID in .env (stable shop slug, same on live/staging/laptop)}"
: "${SHOPWARE_DEPLOY_ENV:?Set SHOPWARE_DEPLOY_ENV in .env (live|staging|playground|dev)}"

SHOPWARE_DATA_BASE="${SHOPWARE_DATA_BASE:-/var/lib/shopware/data}"
if [[ -z "${COMPOSE_PROJECT_NAME:-}" ]]; then
  COMPOSE_PROJECT_NAME="${SHOPWARE_SHOP_ID}-${SHOPWARE_DEPLOY_ENV}"
  echo "==> COMPOSE_PROJECT_NAME unset; derived ${COMPOSE_PROJECT_NAME}"
fi
if [[ -z "${SHOPWARE_DATA_ROOT:-}" ]]; then
  SHOPWARE_DATA_ROOT="${SHOPWARE_DATA_BASE}/${SHOPWARE_SHOP_ID}/${SHOPWARE_DEPLOY_ENV}"
  echo "==> SHOPWARE_DATA_ROOT unset; derived ${SHOPWARE_DATA_ROOT}"
fi

export IMAGE IMAGE_TAG COMPOSE_PROJECT_NAME SHOPWARE_DATA_ROOT SHOPWARE_SHOP_ID SHOPWARE_DEPLOY_ENV SHOPWARE_DATA_BASE

touch .env.prod

for f in deploy/compose.yaml deploy/compose.prod.yaml deploy/compose.vps.yaml; do
  if [[ ! -f "$f" ]]; then
    echo "Missing ${f} (expected under shop root COMPOSE_DIR=${COMPOSE_DIR})" >&2
    exit 1
  fi
done

COMPOSE=(
  docker compose
  -f deploy/compose.yaml
  -f deploy/compose.prod.yaml
  -f deploy/compose.vps.yaml
)

PROFILE_ARGS=()
IFS=',' read -ra RAW_PROFILES <<< "${COMPOSE_PROFILES:-}"
for p in "${RAW_PROFILES[@]}"; do
  p="${p// /}"
  if [[ -z "$p" ]]; then
    continue
  fi
  if [[ "$p" == "setup" ]]; then
    echo "COMPOSE_PROFILES must not include setup (the script runs that profile itself)" >&2
    exit 1
  fi
  PROFILE_ARGS+=(--profile "$p")
done

has_service() {
  "${COMPOSE[@]}" "${PROFILE_ARGS[@]}" config --services 2>/dev/null | grep -qx "$1"
}

echo "==> Deploying ${IMAGE}:${IMAGE_TAG} from ${COMPOSE_DIR}"

if [[ -f .deployed-tag ]]; then
  cp .deployed-tag .previous-tag
  echo "==> Previous tag: $(cat .previous-tag)"
fi

echo "==> Pulling images"
"${COMPOSE[@]}" "${PROFILE_ARGS[@]}" pull

if has_service mysql; then
  echo "==> Starting mysql"
  "${COMPOSE[@]}" up -d --no-build mysql
fi

if has_service redis; then
  echo "==> Starting redis"
  "${COMPOSE[@]}" --profile redis up -d --no-build redis
fi

echo "==> One-shot setup (shopware-deployment-helper, skip theme/assets)"
"${COMPOSE[@]}" --profile setup run --rm --no-build setup

echo "==> Recreating web (no build)"
"${COMPOSE[@]}" up -d --no-build --remove-orphans web

if [[ ${#PROFILE_ARGS[@]} -gt 0 ]]; then
  echo "==> Starting extra profiles: ${COMPOSE_PROFILES}"
  "${COMPOSE[@]}" "${PROFILE_ARGS[@]}" up -d --no-build
fi

printf '%s\n' "$IMAGE_TAG" > .deployed-tag

if [[ -n "${SMOKE_URL:-}" ]]; then
  echo "==> Smoke ${SMOKE_URL}"
  ok=0
  for _ in $(seq 1 30); do
    if command -v curl >/dev/null 2>&1 && curl -fsS "$SMOKE_URL" >/dev/null; then
      echo "==> Smoke OK"
      ok=1
      break
    fi
    sleep 2
  done
  if [[ "$ok" -ne 1 ]]; then
    echo "Smoke check failed for ${SMOKE_URL}" >&2
    exit 1
  fi
fi

echo "==> Deploy finished ${IMAGE}:${IMAGE_TAG}"
