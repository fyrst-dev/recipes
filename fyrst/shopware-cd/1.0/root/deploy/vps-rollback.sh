#!/usr/bin/env bash
# Roll the VPS Compose stack back to the tag in .previous-tag.
# Never builds the image and never compiles themes/assets.
#
# Required env (source of truth — same as deploy/compose.yaml):
#   IMAGE                  registry/repo — kept from env/.env (not from the tag file)
#   SHOPWARE_SHOP_ID       stable shop slug
#   SHOPWARE_DEPLOY_ENV    live|staging|playground|dev
# IMAGE_TAG is always read from .previous-tag (process env IMAGE_TAG is ignored).
#
# Optional:
#   COMPOSE_DIR, COMPOSE_PROFILES, SMOKE_URL, SHOPWARE_DATA_BASE,
#   COMPOSE_PROJECT_NAME, SHOPWARE_DATA_ROOT  — same as deploy/vps-release.sh
#   PULL_POLICY / SKIP_PULL / --skip-pull     — same as deploy/vps-release.sh
#
# Same compose stack and order as deploy/vps-release.sh:
#   pull (unless skip) → mysql/redis → setup profile → recreate web → extra profiles
# Then optional SMOKE_URL. Writes .deployed-tag only after success.
#
# Usage (from shop root, or via the one-liner printed by a failed release):
#   IMAGE_TAG=$(cat .previous-tag) bash deploy/vps-rollback.sh
#   bash deploy/vps-rollback.sh --dry-run
#
# Compose files (always invoked from shop root COMPOSE_DIR):
#   docker compose --env-file .env -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/vps-common.sh
source "${SCRIPT_DIR}/lib/vps-common.sh"

usage() {
  cat <<'EOF'
Usage: deploy/vps-rollback.sh [--dry-run] [--skip-pull]

Re-deploy IMAGE with IMAGE_TAG from .previous-tag.
Refuses to run if .previous-tag is missing or empty.
Does not rebuild images. Same setup → web order as deploy/vps-release.sh.
Writes .deployed-tag only after a successful rollout (and smoke, if SMOKE_URL).

  --dry-run     Print the compose sequence; do not pull or recreate containers
  --skip-pull   Same-host / air-gap: skip registry pull, PULL_POLICY=never
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      export VPS_DRY_RUN=1
      shift
      ;;
    --skip-pull)
      export SKIP_PULL=1
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

# Snapshot CLI env before .env. IMAGE_TAG from the environment is ignored;
# .previous-tag is the only tag source (keep IMAGE from env/.env).
vps_cd_shop_root
CI_IMAGE="${IMAGE:-}"
CI_SMOKE_URL="${SMOKE_URL:-}"
CI_PROFILES="${COMPOSE_PROFILES:-}"
CI_SKIP_PULL="${SKIP_PULL:-}"
CI_PULL_POLICY="${PULL_POLICY:-}"
vps_load_shop_env
IMAGE="${CI_IMAGE:-${IMAGE:-}}"
SMOKE_URL="${CI_SMOKE_URL:-${SMOKE_URL:-}}"
COMPOSE_PROFILES="${CI_PROFILES:-${COMPOSE_PROFILES:-}}"
if [[ -n "${CI_SKIP_PULL:-}" ]]; then
  SKIP_PULL="${CI_SKIP_PULL}"
fi
if [[ -n "${CI_PULL_POLICY:-}" ]]; then
  PULL_POLICY="${CI_PULL_POLICY}"
fi
unset CI_IMAGE_TAG IMAGE_TAG || true

vps_require_image
vps_require_sot
vps_read_previous_tag
vps_require_image_tag
vps_derive_identity
vps_apply_pull_policy
touch .env.prod
vps_init_compose
vps_parse_profiles

vps_log "Rollback to ${IMAGE}:${IMAGE_TAG} (same compose stack as vps-release.sh)"
vps_rollout

if ! vps_smoke; then
  vps_err "Smoke check failed for ${SMOKE_URL} after rollback"
  vps_err "Stack is on ${IMAGE}:${IMAGE_TAG} but .deployed-tag was not updated"
  exit 1
fi

if [[ "${VPS_DRY_RUN}" -eq 1 ]]; then
  vps_log "DRY-RUN would write .deployed-tag=${IMAGE_TAG}"
else
  vps_write_deployed_tag
fi

vps_log "Rollback finished ${IMAGE}:${IMAGE_TAG}"
