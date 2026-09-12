#!/usr/bin/env bash
# Backup Shopware runtime (DB + bind-mount trees) to BACKUP_TARGET.
#
# Distinct from deploy/sync-runtime.sh (live → staging/dev clone). Sync is not
# a backup: it copies onto another shop stack on the same or another host and
# refuses to restore onto live. This script is the backup path and MUST run on
# SHOPWARE_DEPLOY_ENV=live (cron on live).
#
# Reuses dump/rsync helpers by calling:
#   bash deploy/sync-runtime.sh snapshot --from local --data …
# then copies that snapshot into a timestamped artifact under BACKUP_TARGET
# (local path, second disk, or SSH). Retention prune is BACKUP_KEEP_DAYS.
#
# Non-goals: WAL/PITR, S3.
#
# Usage: deploy/backup-runtime.sh <backup|prune|restore|help> [options]
# See deploy/backup-runtime.md and deploy/backup.env.example.

set -euo pipefail

case "$-" in
  *x*)
    printf 'ERROR: refusing to run with xtrace (credentials may be in the environment)\n' >&2
    exit 1
    ;;
esac

umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/vps-common.sh
source "${SCRIPT_DIR}/lib/vps-common.sh"

DEFAULT_KEEP_DAYS=14
DEFAULT_DATA="db,media,files,thumbnail,theme,sitemap"
COMMAND=""
DATA_SPEC="all"
DRY_RUN=0
FROM_ARTIFACT=""
CONFIRM_RESTORE=0
ALLOW_LIVE_RESTORE=0

BACKUP_IS_SSH=0
BACKUP_SSH_USER=""
BACKUP_SSH_HOST=""
BACKUP_SSH_PORT="22"
BACKUP_PATH=""
ARTIFACT_STAMP=""
ARTIFACT_REL=""
LOCAL_ARTIFACT=""

log() { vps_log "$@"; }
err() { vps_err "$@"; }
die() { vps_die "$@"; }

usage() {
  cat <<'EOF'
Usage: deploy/backup-runtime.sh <command> [options]

This is the VPS backup path. It is not deploy/sync-runtime.sh.
Allowed (and expected) on SHOPWARE_DEPLOY_ENV=live.

Commands:
  backup    Snapshot DB + bind-mount trees into BACKUP_TARGET (timestamped)
  prune     Delete artifacts older than BACKUP_KEEP_DAYS (also runs after backup)
  restore   Restore one artifact onto THIS host (disaster recovery)
  help      Show this help

Options:
  --data <list>|all     db,media,files,thumbnail,theme,sitemap (default all)
  --dry-run             Print actions; do not dump, copy, prune, or restore
  --from <stamp|dir>    restore: artifact timestamp or path under the shop/env prefix
  --i-understand-this-restores-this-host
                        restore: required confirmation (or BACKUP_CONFIRM_RESTORE=1)

Environment (see deploy/backup.env.example; no secrets in this script):
  BACKUP_TARGET          Required for backup/prune. Local path, second disk, or
                         SSH: user@host:/path  or  ssh://user@host:22/abs/path
  BACKUP_KEEP_DAYS       Daily retention (default 14). 0 = keep forever
  BACKUP_SSH_KEY         Optional identity file for SSH targets
  BACKUP_SSH_PORT        Default 22 (overridden by ssh:// URL)
  BACKUP_ALLOW_LIVE_RESTORE  restore onto live requires this =1
  SHOPWARE_SHOP_ID / SHOPWARE_DEPLOY_ENV  source of truth (same as Compose)
  SHOPWARE_DATA_BASE / SHOPWARE_DATA_ROOT  optional; derived when unset

Cron (run ON live):

  20 2 * * * cd /opt/shopware/acme-live && bash deploy/backup-runtime.sh backup
EOF
}

need_value() {
  local flag=$1
  local value=${2:-}
  if [[ -z "$value" || "$value" == --* ]]; then
    die "${flag} requires a value"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    backup | prune | restore | help | -h | --help)
      if [[ "$1" == help || "$1" == -h || "$1" == --help ]]; then
        COMMAND="help"
      else
        COMMAND=$1
      fi
      shift
      ;;
    --data)
      need_value "$1" "${2:-}"
      DATA_SPEC=$2
      shift 2
      ;;
    --data=*)
      DATA_SPEC="${1#*=}"
      shift
      ;;
    --from)
      need_value "$1" "${2:-}"
      FROM_ARTIFACT=$2
      shift 2
      ;;
    --from=*)
      FROM_ARTIFACT="${1#*=}"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      export VPS_DRY_RUN=1
      shift
      ;;
    --i-understand-this-restores-this-host)
      CONFIRM_RESTORE=1
      shift
      ;;
    -*)
      die "Unknown option: $1 (try --help)"
      ;;
    *)
      die "Unexpected argument: $1 (try --help)"
      ;;
  esac
done

if [[ -z "$COMMAND" ]]; then
  usage
  die "Missing command (backup, prune, or restore)"
fi

if [[ "$COMMAND" == "help" ]]; then
  usage
  exit 0
fi

vps_cd_shop_root
vps_snapshot_cli_env
PRESET_BACKUP_TARGET="${BACKUP_TARGET:-}"
PRESET_BACKUP_KEEP="${BACKUP_KEEP_DAYS:-}"
PRESET_BACKUP_SSH_KEY="${BACKUP_SSH_KEY:-}"
PRESET_BACKUP_SSH_PORT="${BACKUP_SSH_PORT:-}"
vps_load_shop_env
vps_load_env_file deploy/backup.env
vps_restore_cli_env
BACKUP_TARGET="${PRESET_BACKUP_TARGET:-${BACKUP_TARGET:-}}"
BACKUP_KEEP_DAYS="${PRESET_BACKUP_KEEP:-${BACKUP_KEEP_DAYS:-$DEFAULT_KEEP_DAYS}}"
BACKUP_SSH_KEY="${PRESET_BACKUP_SSH_KEY:-${BACKUP_SSH_KEY:-}}"
BACKUP_SSH_PORT="${PRESET_BACKUP_SSH_PORT:-${BACKUP_SSH_PORT:-22}}"

if [[ -n "${BACKUP_CONFIRM_RESTORE:-}" ]] && vps_env_truthy "$BACKUP_CONFIRM_RESTORE"; then
  CONFIRM_RESTORE=1
fi
if [[ -n "${BACKUP_ALLOW_LIVE_RESTORE:-}" ]] && vps_env_truthy "$BACKUP_ALLOW_LIVE_RESTORE"; then
  ALLOW_LIVE_RESTORE=1
fi

vps_require_image
vps_require_sot
vps_derive_identity
touch .env.prod
vps_init_compose

IMAGE_TAG="${IMAGE_TAG:-latest}"
export IMAGE IMAGE_TAG

BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-$DEFAULT_KEEP_DAYS}"
BACKUP_TARGET="${BACKUP_TARGET:-}"
BACKUP_SSH_PORT="${BACKUP_SSH_PORT:-22}"

if [[ "$DATA_SPEC" == "all" ]]; then
  DATA_SPEC=$DEFAULT_DATA
fi

lower_s() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

parse_backup_target() {
  local raw="${BACKUP_TARGET}"
  BACKUP_IS_SSH=0
  BACKUP_SSH_USER=""
  BACKUP_SSH_HOST=""
  BACKUP_SSH_PORT="${BACKUP_SSH_PORT:-22}"
  BACKUP_PATH=""

  if [[ -z "$raw" ]]; then
    die "BACKUP_TARGET is required (local path, second disk, or user@host:/path). See deploy/backup.env.example."
  fi

  if [[ "$raw" == ssh://* ]]; then
    BACKUP_IS_SSH=1
    local rest="${raw#ssh://}"
    local hostpart pathpart
    if [[ "$rest" == *"/"* ]]; then
      hostpart="${rest%%/*}"
      pathpart="/${rest#*/}"
    else
      die "ssh:// BACKUP_TARGET must include an absolute path (ssh://user@host:22/var/backups/shopware)"
    fi
    if [[ "$hostpart" == *"@"* ]]; then
      BACKUP_SSH_USER="${hostpart%%@*}"
      hostpart="${hostpart#*@}"
    fi
    if [[ "$hostpart" == *"]:"* ]]; then
      die "IPv6 ssh:// with port: use user@[::1]:22/path via user@host:/path form instead"
    fi
    if [[ "$hostpart" == *:* ]]; then
      BACKUP_SSH_HOST="${hostpart%%:*}"
      BACKUP_SSH_PORT="${hostpart#*:}"
    else
      BACKUP_SSH_HOST=$hostpart
    fi
    BACKUP_PATH=$pathpart
    return
  fi

  if [[ "$raw" == *:* && "$raw" != /* && "$raw" != ./* ]]; then
    # user@host:/path or host:/path (not a Windows drive)
    BACKUP_IS_SSH=1
    local left="${raw%%:*}"
    BACKUP_PATH="${raw#*:}"
    if [[ "$left" == *"@"* ]]; then
      BACKUP_SSH_USER="${left%%@*}"
      BACKUP_SSH_HOST="${left#*@}"
    else
      BACKUP_SSH_HOST=$left
    fi
    if [[ "$BACKUP_PATH" != /* ]]; then
      BACKUP_PATH="/${BACKUP_PATH}"
    fi
    return
  fi

  BACKUP_PATH=$raw
}

ssh_cmd() {
  SSH_CMD=(ssh -o BatchMode=yes -o ConnectTimeout=15)
  SSH_CMD+=(-p "${BACKUP_SSH_PORT}")
  if [[ -n "${BACKUP_SSH_KEY:-}" ]]; then
    SSH_CMD+=(-o IdentitiesOnly=yes -i "${BACKUP_SSH_KEY}")
  fi
  if [[ -n "${BACKUP_SSH_USER}" ]]; then
    SSH_TARGET="${BACKUP_SSH_USER}@${BACKUP_SSH_HOST}"
  else
    SSH_TARGET="${BACKUP_SSH_HOST}"
  fi
}

artifact_relpath() {
  printf '%s/%s/%s\n' "$SHOPWARE_SHOP_ID" "$SHOPWARE_DEPLOY_ENV" "$1"
}

remote_sh() {
  local payload=$1
  printf '%s\n' "$payload" | "${SSH_CMD[@]}" "$SSH_TARGET" bash -s
}

ensure_parent_dirs() {
  local dest=$1
  if [[ "$BACKUP_IS_SSH" -eq 1 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "DRY-RUN ssh mkdir -p ${dest}"
      return
    fi
    remote_sh "mkdir -p $(printf '%q' "$dest")"
    return
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN mkdir -p ${dest}"
    return
  fi
  mkdir -p "$dest"
  chmod 700 "$dest" 2>/dev/null || true
}

write_backup_manifest() {
  local dest=$1
  local mf="${dest}/BACKUP_MANIFEST.txt"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN would write ${mf}"
    return
  fi
  {
    printf 'shopware-vps-backup 1\n'
    printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'stamp=%s\n' "$ARTIFACT_STAMP"
    printf 'shop_id=%s\n' "$SHOPWARE_SHOP_ID"
    printf 'deploy_env=%s\n' "$SHOPWARE_DEPLOY_ENV"
    printf 'host=%s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'compose_dir=%s\n' "$COMPOSE_DIR"
    printf 'project=%s\n' "${COMPOSE_PROJECT_NAME}"
    printf 'data=%s\n' "$DATA_SPEC"
    printf 'data_root=%s\n' "$SHOPWARE_DATA_ROOT"
    printf 'backup_target=%s\n' "$BACKUP_TARGET"
    printf 'sync_is_not_backup=true\n'
    printf 'object_storage=out-of-scope\n'
    printf 'wal_pitr=out-of-scope\n'
  } >"$mf"
  if command -v sha256sum >/dev/null 2>&1; then
    (
      cd "$dest"
      find . -type f ! -name SHA256SUMS ! -name BACKUP_MANIFEST.txt -print0 \
        | sort -z \
        | xargs -0 -r sha256sum
    ) >"${dest}/SHA256SUMS"
  fi
}

copy_artifact_to_target() {
  local src=$1
  local rel=$2
  if [[ "$BACKUP_IS_SSH" -eq 1 ]]; then
    local dest="${BACKUP_PATH%/}/${rel}"
    ensure_parent_dirs "$(dirname "$dest")"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "DRY-RUN rsync ${src}/ → ${SSH_TARGET}:${dest}/"
      return
    fi
    if ! command -v rsync >/dev/null 2>&1; then
      die "rsync is required to copy backups to an SSH BACKUP_TARGET"
    fi
    rsync -aH --delete --numeric-ids -e "${SSH_CMD[*]}" "${src%/}/" "${SSH_TARGET}:${dest%/}/"
    return
  fi
  local dest="${BACKUP_PATH%/}/${rel}"
  if [[ "$src" == "$dest" ]]; then
    return
  fi
  ensure_parent_dirs "$(dirname "$dest")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN rsync/cp ${src}/ → ${dest}/"
    return
  fi
  mkdir -p "$dest"
  chmod 700 "$dest" 2>/dev/null || true
  if command -v rsync >/dev/null 2>&1; then
    rsync -aH --delete --numeric-ids "${src%/}/" "${dest%/}/"
  else
    cp -a "${src%/}/." "${dest%/}/"
  fi
}

list_artifact_stamps() {
  if [[ "$BACKUP_IS_SSH" -eq 1 ]]; then
    remote_sh "ls -1 $(printf '%q' "${BACKUP_PATH%/}/${SHOPWARE_SHOP_ID}/${SHOPWARE_DEPLOY_ENV}") 2>/dev/null || true"
    return
  fi
  local dir="${BACKUP_PATH%/}/${SHOPWARE_SHOP_ID}/${SHOPWARE_DEPLOY_ENV}"
  if [[ ! -d "$dir" ]]; then
    return
  fi
  ls -1 "$dir" 2>/dev/null || true
}

stamp_is_old() {
  local stamp=$1
  local keep=$2
  if [[ "$keep" -eq 0 ]]; then
    return 1
  fi
  if [[ ! "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
    return 1
  fi
  local cutoff
  cutoff="$(date -u -d "${keep} days ago" +%Y%m%dT%H%M%SZ 2>/dev/null || date -u -v-"${keep}"d +%Y%m%dT%H%M%SZ 2>/dev/null || true)"
  if [[ -z "$cutoff" ]]; then
    die "Cannot compute retention cutoff (need GNU date -d or BSD date -v)"
  fi
  [[ "$stamp" < "$cutoff" ]]
}

prune_artifacts() {
  local keep="${BACKUP_KEEP_DAYS}"
  if [[ ! "$keep" =~ ^[0-9]+$ ]]; then
    die "BACKUP_KEEP_DAYS must be a non-negative integer (got ${keep})"
  fi
  if [[ "$keep" -eq 0 ]]; then
    log "BACKUP_KEEP_DAYS=0 — keeping all artifacts"
    return
  fi
  log "Pruning artifacts older than ${keep} daily backups (stamp < $(date -u -d "${keep} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "${keep}d ago")) under ${SHOPWARE_SHOP_ID}/${SHOPWARE_DEPLOY_ENV}"
  local stamp rel dest
  while IFS= read -r stamp; do
    [[ -z "$stamp" ]] && continue
    if stamp_is_old "$stamp" "$keep"; then
      rel="$(artifact_relpath "$stamp")"
      if [[ "$BACKUP_IS_SSH" -eq 1 ]]; then
        dest="${BACKUP_PATH%/}/${rel}"
        log "Prune ${SSH_TARGET}:${dest}"
        if [[ "$DRY_RUN" -eq 1 ]]; then
          log "DRY-RUN rm -rf ${dest}"
          continue
        fi
        remote_sh "rm -rf $(printf '%q' "$dest")"
      else
        dest="${BACKUP_PATH%/}/${rel}"
        log "Prune ${dest}"
        if [[ "$DRY_RUN" -eq 1 ]]; then
          log "DRY-RUN rm -rf ${dest}"
          continue
        fi
        rm -rf "$dest"
      fi
    fi
  done < <(list_artifact_stamps)
}

lock_backup() {
  local lock="${COMPOSE_DIR}/var/backup-runtime.lock"
  mkdir -p "$(dirname "$lock")"
  exec 9>"$lock"
  if command -v flock >/dev/null 2>&1; then
    if ! flock -n 9; then
      die "Another backup-runtime.sh run holds ${lock}. Cron overlap — wait or remove a stale lock."
    fi
  fi
}

do_backup() {
  parse_backup_target
  if [[ "$BACKUP_IS_SSH" -eq 1 ]]; then
    ssh_cmd
    if [[ "$DRY_RUN" -eq 0 ]]; then
      log "Probing SSH ${SSH_TARGET}"
      if ! "${SSH_CMD[@]}" "$SSH_TARGET" true; then
        die "SSH to ${SSH_TARGET} failed (BatchMode). Check BACKUP_TARGET / BACKUP_SSH_KEY."
      fi
    fi
  fi

  ARTIFACT_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  ARTIFACT_REL="$(artifact_relpath "$ARTIFACT_STAMP")"
  log "Backup ${SHOPWARE_SHOP_ID}/${SHOPWARE_DEPLOY_ENV} data=${DATA_SPEC} → ${BACKUP_TARGET}/${ARTIFACT_REL}"
  log "SHOPWARE_DEPLOY_ENV=${SHOPWARE_DEPLOY_ENV} (live is allowed; this is not sync)"

  if [[ "$BACKUP_IS_SSH" -eq 1 ]]; then
    LOCAL_ARTIFACT="${COMPOSE_DIR}/var/backup-work/${ARTIFACT_STAMP}"
  else
    LOCAL_ARTIFACT="${BACKUP_PATH%/}/${ARTIFACT_REL}"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN snapshot via deploy/sync-runtime.sh --snapshot-dir ${LOCAL_ARTIFACT}"
    log "DRY-RUN then checksum/manifest + copy to BACKUP_TARGET if needed"
    prune_artifacts
    return
  fi

  mkdir -p "$LOCAL_ARTIFACT"
  chmod 700 "$LOCAL_ARTIFACT"

  # Reuse dump + bind-mount snapshot from sync (snapshot is allowed on live).
  COMPOSE_DIR="$COMPOSE_DIR" IMAGE="$IMAGE" IMAGE_TAG="$IMAGE_TAG" \
    SHOPWARE_SHOP_ID="$SHOPWARE_SHOP_ID" SHOPWARE_DEPLOY_ENV="$SHOPWARE_DEPLOY_ENV" \
    SHOPWARE_DATA_BASE="$SHOPWARE_DATA_BASE" SHOPWARE_DATA_ROOT="$SHOPWARE_DATA_ROOT" \
    bash "${SCRIPT_DIR}/sync-runtime.sh" snapshot --from local --data "$DATA_SPEC" --snapshot-dir "$LOCAL_ARTIFACT"

  write_backup_manifest "$LOCAL_ARTIFACT"
  copy_artifact_to_target "$LOCAL_ARTIFACT" "$ARTIFACT_REL"

  if [[ "$BACKUP_IS_SSH" -eq 1 ]]; then
    rm -rf "$LOCAL_ARTIFACT"
  fi

  prune_artifacts
  log "Backup finished ${BACKUP_TARGET}/${ARTIFACT_REL}"
}

fetch_artifact_local() {
  local spec=$1
  local stamp=$spec
  if [[ "$spec" == */* || "$spec" == /* ]]; then
    if [[ -d "$spec" ]]; then
      LOCAL_ARTIFACT=$spec
      return
    fi
    die "Artifact directory not found: ${spec}"
  fi
  ARTIFACT_REL="$(artifact_relpath "$stamp")"
  if [[ "$BACKUP_IS_SSH" -eq 1 ]]; then
    LOCAL_ARTIFACT="${COMPOSE_DIR}/var/backup-work/restore-${stamp}"
    local src="${BACKUP_PATH%/}/${ARTIFACT_REL}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "DRY-RUN rsync ${SSH_TARGET}:${src}/ → ${LOCAL_ARTIFACT}/"
      return
    fi
    mkdir -p "$LOCAL_ARTIFACT"
    rsync -aH --delete --numeric-ids -e "${SSH_CMD[*]}" "${SSH_TARGET}:${src%/}/" "${LOCAL_ARTIFACT%/}/"
    return
  fi
  LOCAL_ARTIFACT="${BACKUP_PATH%/}/${ARTIFACT_REL}"
  if [[ "$DRY_RUN" -eq 0 && ! -d "$LOCAL_ARTIFACT" ]]; then
    die "Artifact not found: ${LOCAL_ARTIFACT}"
  fi
}

do_restore() {
  parse_backup_target
  if [[ -z "$FROM_ARTIFACT" ]]; then
    die "restore requires --from <timestamp|directory>"
  fi
  if [[ "$CONFIRM_RESTORE" -ne 1 ]]; then
    die "Restore onto this host needs --i-understand-this-restores-this-host (or BACKUP_CONFIRM_RESTORE=1). This overwrites DB and bind mounts."
  fi
  local env_lc
  env_lc="$(lower_s "${SHOPWARE_DEPLOY_ENV}")"
  if [[ "$env_lc" == "live" && "$ALLOW_LIVE_RESTORE" -ne 1 ]]; then
    die "Refusing restore onto SHOPWARE_DEPLOY_ENV=live without BACKUP_ALLOW_LIVE_RESTORE=1 (disaster recovery only; quarterly drill on staging does not need this)."
  fi
  if [[ "$BACKUP_IS_SSH" -eq 1 ]]; then
    ssh_cmd
  fi
  fetch_artifact_local "$FROM_ARTIFACT"
  log "Restoring ${LOCAL_ARTIFACT} into ${SHOPWARE_DATA_ROOT} (SYNC_ALLOW_LIVE_RESTORE for live DR)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN bash deploy/sync-runtime.sh restore --data ${DATA_SPEC} --snapshot-dir ${LOCAL_ARTIFACT}"
    return
  fi
  COMPOSE_DIR="$COMPOSE_DIR" IMAGE="$IMAGE" IMAGE_TAG="$IMAGE_TAG" \
    SHOPWARE_SHOP_ID="$SHOPWARE_SHOP_ID" SHOPWARE_DEPLOY_ENV="$SHOPWARE_DEPLOY_ENV" \
    SHOPWARE_DATA_BASE="$SHOPWARE_DATA_BASE" SHOPWARE_DATA_ROOT="$SHOPWARE_DATA_ROOT" \
    SYNC_ALLOW_LIVE_RESTORE=1 \
    bash "${SCRIPT_DIR}/sync-runtime.sh" restore --data "$DATA_SPEC" --snapshot-dir "$LOCAL_ARTIFACT"
  log "Restore finished from ${FROM_ARTIFACT}. Rewrite sales-channel URLs if this is not a same-host drill."
}

do_prune() {
  parse_backup_target
  if [[ "$BACKUP_IS_SSH" -eq 1 ]]; then
    ssh_cmd
  fi
  prune_artifacts
}

lock_backup
log "Runtime backup ${COMMAND} shop=${SHOPWARE_SHOP_ID} deploy_env=${SHOPWARE_DEPLOY_ENV} target=${BACKUP_TARGET:-unset} keep_days=${BACKUP_KEEP_DAYS} dry-run=${DRY_RUN}"

case "$COMMAND" in
  backup) do_backup ;;
  prune) do_prune ;;
  restore) do_restore ;;
  *) die "Unknown command: ${COMMAND}" ;;
esac
