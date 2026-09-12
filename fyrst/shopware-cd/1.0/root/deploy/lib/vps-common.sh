#!/usr/bin/env bash
# Shared helpers for VPS Compose scripts (release, rollback, backup).
# Source after `set -euo pipefail`. Caller must set SCRIPT_DIR to deploy/.
#
# Compose files (always from shop root COMPOSE_DIR):
#   docker compose --env-file .env -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml
#
# Never builds images. Callers pass --no-build / pull only.

vps_log() { printf '==> %s\n' "$*"; }
vps_err() { printf 'ERROR: %s\n' "$*" >&2; }
vps_warn() { printf 'WARNING: %s\n' "$*" >&2; }
vps_die() { vps_err "$@"; exit 1; }

VPS_COMPOSE_FILES=(
  deploy/compose.yaml
  deploy/compose.prod.yaml
  deploy/compose.vps.yaml
)

DEFAULT_DATA_BASE="/var/lib/shopware/data"
VPS_DRY_RUN="${VPS_DRY_RUN:-0}"
PROFILE_ARGS=()
COMPOSE=()
COMPOSE_STR=""

vps_cd_shop_root() {
  COMPOSE_DIR="${COMPOSE_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
  cd "$COMPOSE_DIR" || vps_die "Cannot cd to COMPOSE_DIR=${COMPOSE_DIR}"
}

vps_load_env_file() {
  local f=$1
  if [[ -f "$f" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$f"
    set +a
  fi
}

vps_load_shop_env() {
  vps_load_env_file .env
  vps_load_env_file .env.prod
}

# Capture process-env values before sourcing .env (CI / documented IMAGE_TAG=… win).
vps_snapshot_cli_env() {
  CI_IMAGE="${IMAGE:-}"
  CI_IMAGE_TAG="${IMAGE_TAG:-}"
  CI_SMOKE_URL="${SMOKE_URL:-}"
  CI_PROFILES="${COMPOSE_PROFILES:-}"
  CI_ROLLBACK_ON_SMOKE_FAIL="${ROLLBACK_ON_SMOKE_FAIL:-}"
}

vps_restore_cli_env() {
  IMAGE="${CI_IMAGE:-${IMAGE:-}}"
  IMAGE_TAG="${CI_IMAGE_TAG:-${IMAGE_TAG:-}}"
  SMOKE_URL="${CI_SMOKE_URL:-${SMOKE_URL:-}}"
  COMPOSE_PROFILES="${CI_PROFILES:-${COMPOSE_PROFILES:-}}"
  if [[ -n "${CI_ROLLBACK_ON_SMOKE_FAIL:-}" ]]; then
    ROLLBACK_ON_SMOKE_FAIL="${CI_ROLLBACK_ON_SMOKE_FAIL}"
  fi
}

vps_require_image() {
  : "${IMAGE:?Set IMAGE to the registry repository}"
}

vps_require_image_tag() {
  : "${IMAGE_TAG:?Set IMAGE_TAG to the git SHA (or previous tag for rollback)}"
}

vps_require_sot() {
  : "${SHOPWARE_SHOP_ID:?Set SHOPWARE_SHOP_ID in .env (stable shop slug, same on live/staging/laptop)}"
  : "${SHOPWARE_DEPLOY_ENV:?Set SHOPWARE_DEPLOY_ENV in .env (live|staging|playground|dev)}"
}

vps_derive_identity() {
  SHOPWARE_DATA_BASE="${SHOPWARE_DATA_BASE:-$DEFAULT_DATA_BASE}"
  if [[ -z "${COMPOSE_PROJECT_NAME:-}" ]]; then
    COMPOSE_PROJECT_NAME="${SHOPWARE_SHOP_ID}-${SHOPWARE_DEPLOY_ENV}"
    vps_log "COMPOSE_PROJECT_NAME unset; derived ${COMPOSE_PROJECT_NAME}"
  fi
  if [[ -z "${SHOPWARE_DATA_ROOT:-}" ]]; then
    SHOPWARE_DATA_ROOT="${SHOPWARE_DATA_BASE}/${SHOPWARE_SHOP_ID}/${SHOPWARE_DEPLOY_ENV}"
    vps_log "SHOPWARE_DATA_ROOT unset; derived ${SHOPWARE_DATA_ROOT}"
  fi
  export IMAGE IMAGE_TAG COMPOSE_PROJECT_NAME SHOPWARE_DATA_ROOT SHOPWARE_SHOP_ID SHOPWARE_DEPLOY_ENV SHOPWARE_DATA_BASE
}

vps_init_compose() {
  local f
  for f in "${VPS_COMPOSE_FILES[@]}"; do
    if [[ ! -f "$f" ]]; then
      vps_die "Missing ${f} (expected under shop root COMPOSE_DIR=${COMPOSE_DIR})"
    fi
  done
  COMPOSE=(
    docker compose
    --env-file .env
    -f deploy/compose.yaml
    -f deploy/compose.prod.yaml
    -f deploy/compose.vps.yaml
  )
  COMPOSE_STR="docker compose --env-file .env -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml"
}

vps_parse_profiles() {
  PROFILE_ARGS=()
  local p
  local IFS=','
  local -a RAW_PROFILES=()
  IFS=',' read -ra RAW_PROFILES <<< "${COMPOSE_PROFILES:-}"
  for p in "${RAW_PROFILES[@]}"; do
    p="${p// /}"
    if [[ -z "$p" ]]; then
      continue
    fi
    if [[ "$p" == "setup" ]]; then
      vps_die "COMPOSE_PROFILES must not include setup (the script runs that profile itself)"
    fi
    PROFILE_ARGS+=(--profile "$p")
  done
}

# Loud warning only. Never auto-enables redis/worker/scheduler (#18).
vps_warn_empty_live_profiles() {
  local env_lc
  env_lc="$(printf '%s' "${SHOPWARE_DEPLOY_ENV:-}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$env_lc" != "live" ]]; then
    return
  fi
  if [[ -n "${COMPOSE_PROFILES:-}" ]]; then
    return
  fi
  vps_warn "SHOPWARE_DEPLOY_ENV=live but COMPOSE_PROFILES is empty."
  vps_warn "redis / worker / scheduler will not start. Recommended live default:"
  vps_warn "  COMPOSE_PROFILES=redis,worker,scheduler"
  vps_warn "Uncomment that in .env (do not auto-enable). See deploy/README.md."
}

vps_has_service() {
  if [[ "${VPS_DRY_RUN}" -eq 1 ]]; then
    return 1
  fi
  "${COMPOSE[@]}" "${PROFILE_ARGS[@]}" config --services 2>/dev/null | grep -qx "$1"
}

vps_write_deployed_tag() {
  printf '%s\n' "$IMAGE_TAG" > .deployed-tag
}

vps_read_previous_tag() {
  if [[ ! -f .previous-tag ]]; then
    vps_die "No .previous-tag (missing). Rollback needs a prior deploy/vps-release.sh run that recorded the running tag. Refusing to guess IMAGE_TAG."
  fi
  local t
  t="$(tr -d '[:space:]' < .previous-tag || true)"
  if [[ -z "$t" ]]; then
    vps_die ".previous-tag is empty. Rollback refuses to guess IMAGE_TAG."
  fi
  IMAGE_TAG="$t"
  export IMAGE_TAG
  vps_log "Rollback IMAGE_TAG from .previous-tag: ${IMAGE_TAG} (IMAGE=${IMAGE} unchanged)"
}

vps_rollback_command() {
  # Literal one-liner for operators / CI logs (do not expand IMAGE_TAG here).
  # shellcheck disable=SC2016
  printf '%s\n' 'IMAGE_TAG=$(cat .previous-tag) bash deploy/vps-rollback.sh'
}

vps_env_truthy() {
  local v
  v="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

vps_env_falsy() {
  local v
  v="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    0 | false | no | off) return 0 ;;
    *) return 1 ;;
  esac
}

# ROLLBACK_ON_SMOKE_FAIL: explicit 1/0 wins. Unset → on for live, off otherwise.
vps_should_auto_rollback() {
  local flag="${ROLLBACK_ON_SMOKE_FAIL:-}"
  if vps_env_truthy "$flag"; then
    return 0
  fi
  if vps_env_falsy "$flag"; then
    return 1
  fi
  local env_lc
  env_lc="$(printf '%s' "${SHOPWARE_DEPLOY_ENV:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$env_lc" == "live" ]]
}

vps_print_smoke_rollback_hint() {
  vps_err "Smoke check failed${1:+ for $1}"
  vps_err "Rollback command: $(vps_rollback_command)"
}

vps_rollout() {
  vps_log "Deploying ${IMAGE}:${IMAGE_TAG} from ${COMPOSE_DIR} (pull + --no-build, never compile themes/assets)"
  if [[ "${VPS_DRY_RUN}" -eq 1 ]]; then
    vps_log "DRY-RUN ${COMPOSE_STR} ${PROFILE_ARGS[*]+${PROFILE_ARGS[*]}} pull"
    vps_log "DRY-RUN start mysql/redis if present, then:"
    vps_log "DRY-RUN ${COMPOSE_STR} --profile setup run --rm --no-build setup"
    vps_log "DRY-RUN ${COMPOSE_STR} up -d --no-build --remove-orphans web"
    if [[ ${#PROFILE_ARGS[@]} -gt 0 ]]; then
      vps_log "DRY-RUN extra profiles: ${COMPOSE_PROFILES}"
    fi
    return
  fi

  vps_log "Pulling images"
  "${COMPOSE[@]}" "${PROFILE_ARGS[@]}" pull

  if vps_has_service mysql; then
    vps_log "Starting mysql"
    "${COMPOSE[@]}" up -d --no-build mysql
  fi

  if vps_has_service redis || [[ "${COMPOSE_PROFILES:-}" == *redis* ]]; then
    vps_log "Starting redis"
    "${COMPOSE[@]}" --profile redis up -d --no-build redis
  fi

  vps_log "One-shot setup (shopware-deployment-helper, skip theme/assets)"
  "${COMPOSE[@]}" --profile setup run --rm --no-build setup

  vps_log "Recreating web (no build)"
  "${COMPOSE[@]}" up -d --no-build --remove-orphans web

  if [[ ${#PROFILE_ARGS[@]} -gt 0 ]]; then
    vps_log "Starting extra profiles: ${COMPOSE_PROFILES}"
    "${COMPOSE[@]}" "${PROFILE_ARGS[@]}" up -d --no-build
  fi
}

vps_smoke() {
  if [[ -z "${SMOKE_URL:-}" ]]; then
    return 0
  fi
  vps_log "Smoke ${SMOKE_URL}"
  if [[ "${VPS_DRY_RUN}" -eq 1 ]]; then
    vps_log "DRY-RUN would GET ${SMOKE_URL}"
    return 0
  fi
  local ok=0
  local _
  for _ in $(seq 1 30); do
    if command -v curl >/dev/null 2>&1 && curl -fsS "$SMOKE_URL" >/dev/null; then
      vps_log "Smoke OK"
      ok=1
      break
    fi
    sleep 2
  done
  if [[ "$ok" -ne 1 ]]; then
    return 1
  fi
  return 0
}

vps_bootstrap() {
  vps_cd_shop_root
  vps_snapshot_cli_env
  vps_load_shop_env
  vps_restore_cli_env
  vps_require_image
  vps_require_sot
  vps_derive_identity
  touch .env.prod
  vps_init_compose
  vps_parse_profiles
}
