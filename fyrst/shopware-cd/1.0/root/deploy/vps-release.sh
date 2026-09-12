#!/usr/bin/env bash
# Run on the VPS (or via SSH from CI) after the image has been pushed.
# Never builds the image and never compiles themes/assets.
#
# Required env (source of truth — same as deploy/compose.yaml):
#   IMAGE                  registry/repo (e.g. ghcr.io/fyrst-dev/shop-name) — no real defaults
#   IMAGE_TAG              full git SHA (or a rollback tag)
#   SHOPWARE_SHOP_ID       stable shop slug (same on live + staging + laptop)
#   SHOPWARE_DEPLOY_ENV    live|staging|playground|dev
# Optional:
#   COMPOSE_DIR            shop checkout (default: repository root next to deploy/)
#   COMPOSE_PROFILES       comma-separated: redis,worker,scheduler  (never include "setup")
#                          Live recommendation: redis,worker,scheduler (uncomment in .env).
#                          Empty on live → loud warning; this script does not auto-enable.
#   SMOKE_URL              HTTP URL to probe after up (e.g. http://127.0.0.1:8000)
#   SHOPWARE_DATA_BASE     prefix helper (default /var/lib/shopware/data)
#   COMPOSE_PROJECT_NAME   scripts/docs only; unset → ${SHOPWARE_SHOP_ID}-${SHOPWARE_DEPLOY_ENV}
#   SHOPWARE_DATA_ROOT     scripts/docs only; unset → $SHOPWARE_DATA_BASE/$SHOPWARE_SHOP_ID/$SHOPWARE_DEPLOY_ENV
#   ROLLBACK_ON_SMOKE_FAIL 1/0. Unset → on when SHOPWARE_DEPLOY_ENV=live, off otherwise.
#
# Compose interpolates project name + bind mounts from shop id + env (and
# optional SHOPWARE_DATA_BASE). It does not fail when COMPOSE_PROJECT_NAME /
# SHOPWARE_DATA_ROOT are absent. This script still derives those when unset
# (and prefers them when set) so logs and tools have the expanded strings.
#
# CI-exported IMAGE / IMAGE_TAG always win over .env (which often has IMAGE_TAG=latest).
#
# Compose files (always invoked from shop root COMPOSE_DIR):
#   docker compose --env-file .env -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml
#
# On SMOKE_URL failure this script always prints:
#   IMAGE_TAG=$(cat .previous-tag) bash deploy/vps-rollback.sh
# and, when auto-rollback is on, runs deploy/vps-rollback.sh (pull + --no-build).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/vps-common.sh
source "${SCRIPT_DIR}/lib/vps-common.sh"

usage() {
  cat <<'EOF'
Usage: deploy/vps-release.sh [--dry-run]

Pull IMAGE:IMAGE_TAG and recreate the VPS stack (--no-build). Writes
.deployed-tag only after setup/web succeed and optional SMOKE_URL passes.

  --dry-run   Print the compose sequence; do not pull or recreate containers
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      export VPS_DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      vps_die "Unknown option: $1 (try --help)"
      ;;
    *)
      vps_die "Unexpected argument: $1 (try --help)"
      ;;
  esac
done

vps_bootstrap
vps_require_image_tag
vps_warn_empty_live_profiles

if [[ -f .deployed-tag ]]; then
  cp .deployed-tag .previous-tag
  vps_log "Previous tag: $(tr -d '[:space:]' < .previous-tag)"
fi

vps_rollout

if ! vps_smoke; then
  vps_print_smoke_rollback_hint "${SMOKE_URL}"
  if vps_should_auto_rollback; then
    vps_log "ROLLBACK_ON_SMOKE_FAIL on (SHOPWARE_DEPLOY_ENV=${SHOPWARE_DEPLOY_ENV}; live default is on, others off unless ROLLBACK_ON_SMOKE_FAIL=1)"
    if [[ ! -f .previous-tag ]] || [[ -z "$(tr -d '[:space:]' < .previous-tag 2>/dev/null || true)" ]]; then
      vps_err "Cannot auto-rollback: .previous-tag missing or empty (first deploy, or no recorded prior tag)"
      exit 1
    fi
    # Rollback reads IMAGE_TAG from .previous-tag; do not pass the failed tag.
    unset IMAGE_TAG
    if ! IMAGE="${IMAGE}" SMOKE_URL="${SMOKE_URL:-}" COMPOSE_DIR="${COMPOSE_DIR}" \
      COMPOSE_PROFILES="${COMPOSE_PROFILES:-}" \
      bash "${SCRIPT_DIR}/vps-rollback.sh"; then
      vps_err "Auto-rollback failed. Stack may be on the new tag. Retry: $(vps_rollback_command)"
      exit 1
    fi
    vps_err "Rolled back after smoke failure. Release still exits 1 so CI does not treat the new tag as live."
    exit 1
  fi
  vps_log "Auto-rollback skipped (SHOPWARE_DEPLOY_ENV=${SHOPWARE_DEPLOY_ENV}; set ROLLBACK_ON_SMOKE_FAIL=1 to enable)"
  exit 1
fi

if [[ "${VPS_DRY_RUN}" -eq 1 ]]; then
  vps_log "DRY-RUN would write .deployed-tag=${IMAGE_TAG}"
else
  vps_write_deployed_tag
fi

vps_log "Deploy finished ${IMAGE}:${IMAGE_TAG}"
