#!/usr/bin/env bash
# Snapshot / restore / sync Shopware runtime data between VPS environments.
#
# Unidirectional pull: run this on the CONSUMER (staging, playground, dev) with
# `--from <source>`. Database + bind-mounted upload trees under
# SHOPWARE_DATA_ROOT stay on the hosts (SQL dump + rsync). Object storage
# (S3 and similar) is out of scope for this VPS path.
#
# Does not call deploy/vps-release.sh and does not change release behaviour.
#
# Do not run with `bash -x` — DATABASE_URL / MYSQL_* may be in the environment.
#
# Required on each host: docker (Compose plugin), bash, OpenSSH client, gzip.
# rsync is required for incremental bind-mount sync (tar is the fallback).
#
# Usage: deploy/sync-runtime.sh <snapshot|restore|sync> [options]
# See deploy/sync-runtime.md and deploy/sync.env.example.

set -euo pipefail

case "$-" in
  *x*)
    printf 'ERROR: refusing to run with xtrace (credentials may be in the environment)\n' >&2
    exit 1
    ;;
esac

umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

DEFAULT_DATA="db,media,files,thumbnail,theme,sitemap"

COMMAND=""
FROM="local"
DATA_SPEC="all"
SNAPSHOT_DIR=""
DRY_RUN=0
SKIP_DB=0
SKIP_VOLUMES=0

SOURCE_IS_LOCAL=1
SSH_TARGET=""
REMOTE_PATH=""
PROJECT_NAME="shopware"
ARCHIVE_IMAGE="${SYNC_ARCHIVE_IMAGE:-alpine:3.20}"
DEFAULT_DATA_ROOT="/var/lib/shopware/data"
DATA_ROOT=""
REMOTE_DATA_ROOT=""
STOPPED_APP=()
WANT_DB=0
WANT_VOLUMES=()
DATA_ITEMS=()

log() { printf '==> %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
die() { err "$@"; exit 1; }

usage() {
  cat <<'EOF'
Usage: deploy/sync-runtime.sh <command> [options]

Commands:
  snapshot   Dump DB and/or copy bind-mount trees into --snapshot-dir
  restore    Load --snapshot-dir into this host's DB and/or SHOPWARE_DATA_ROOT
  sync       Pull from --from then apply locally (cron path: rsync trees + DB)
  help       Show this help

Options:
  --from <alias>         Source host. "local" = this machine (default for
                         snapshot). Any other alias uses SSH (see env below).
  --data <list>|all      Comma-separated subset, or "all".
                         Default: db,media,files,thumbnail,theme,sitemap
                         (not mysql_data / redis_data — use db for SQL)
  --snapshot-dir <dir>   Work directory (default: <shop>/var/runtime-sync)
  --dry-run              Print actions; do not dump, copy, or restore
  --skip-db              Drop db from --data
  --skip-volumes         Drop files/media/thumbnail/theme/sitemap from --data

Environment (no secrets in this script; see deploy/sync.env.example):
  SYNC_ENV               Consumer name. restore/sync refuse SYNC_ENV=live
                         (also refused when the checkout directory is named live)
  SHOPWARE_DATA_ROOT     Bind-mount root (default /var/lib/shopware/data)
  SYNC_DATA_ROOT         Override for this host (else SHOPWARE_DATA_ROOT)
  SYNC_REMOTE_DATA_ROOT  Bind-mount root on the SSH source
  SYNC_SSH_HOST          Source hostname (default: the --from alias, which
                         may be an ~/.ssh/config Host)
  SYNC_SSH_USER          SSH user
  SYNC_SSH_PORT          SSH port (default 22)
  SYNC_SSH_KEY           Identity file
  SYNC_REMOTE_PATH       Shop checkout on the source (required for SSH)
  SYNC_APP_URL           This environment's public URL (reminder after restore)
  SYNC_POST_RESTORE_CMD  Optional shell command after restore (non-fatal)
  SYNC_ARCHIVE_IMAGE     Image used to tar trees if rsync cannot (default alpine:3.20)
  COMPOSE_DIR            Shop root (default: parent of deploy/)
  COMPOSE_PROJECT_NAME   Overrides compose project (default: name in compose)

Per-alias overrides (example --from live): SYNC_LIVE_SSH_HOST, SYNC_LIVE_SSH_USER,
SYNC_LIVE_SSH_PORT, SYNC_LIVE_SSH_KEY, SYNC_LIVE_REMOTE_PATH, SYNC_LIVE_DATA_ROOT.

Cron (run on staging, pull from live):

  15 2 * * * cd /opt/shopware/staging && bash deploy/sync-runtime.sh sync --from live --data all

Compose files (same as deploy/vps-release.sh, from shop root):
  docker compose -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml
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
    snapshot | restore | sync | help | -h | --help)
      if [[ "$1" == help || "$1" == -h || "$1" == --help ]]; then
        COMMAND="help"
      else
        COMMAND=$1
      fi
      shift
      ;;
    --from)
      need_value "$1" "${2:-}"
      FROM=$2
      shift 2
      ;;
    --from=*)
      FROM="${1#*=}"
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
    --snapshot-dir)
      need_value "$1" "${2:-}"
      SNAPSHOT_DIR=$2
      shift 2
      ;;
    --snapshot-dir=*)
      SNAPSHOT_DIR="${1#*=}"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --skip-db)
      SKIP_DB=1
      shift
      ;;
    --skip-volumes)
      SKIP_VOLUMES=1
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
  die "Missing command (snapshot, restore, or sync)"
fi

if [[ "$COMMAND" == "help" ]]; then
  usage
  exit 0
fi

cd "$COMPOSE_DIR"

PRESET_SYNC_ENV="${SYNC_ENV:-}"
PRESET_IMAGE="${IMAGE:-}"
PRESET_IMAGE_TAG="${IMAGE_TAG:-}"
PRESET_SYNC_DATA_ROOT="${SYNC_DATA_ROOT:-}"

load_env_file() {
  local f=$1
  if [[ -f "$f" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$f"
    set +a
  fi
}

load_env_file .env
load_env_file .env.prod
load_env_file deploy/sync.env

SYNC_ENV="${PRESET_SYNC_ENV:-${SYNC_ENV:-}}"
IMAGE="${PRESET_IMAGE:-${IMAGE:-}}"
IMAGE_TAG="${PRESET_IMAGE_TAG:-${IMAGE_TAG:-latest}}"
export IMAGE IMAGE_TAG

SNAPSHOT_DIR="${SNAPSHOT_DIR:-${SYNC_SNAPSHOT_DIR:-${COMPOSE_DIR}/var/runtime-sync}}"
DATA_ROOT="${PRESET_SYNC_DATA_ROOT:-${SYNC_DATA_ROOT:-${SHOPWARE_DATA_ROOT:-$DEFAULT_DATA_ROOT}}}"

split_csv() {
  local csv=$1
  local IFS=','
  # shellcheck disable=SC2086
  set -- $csv
  local item
  for item in "$@"; do
    item="${item// /}"
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
}

normalize_data() {
  local spec=$1
  local item lower
  local -a raw=()

  if [[ "$spec" == "all" ]]; then
    spec=$DEFAULT_DATA
  fi

  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    raw+=("$item")
  done < <(split_csv "$spec")

  if [[ ${#raw[@]} -eq 0 ]]; then
    die "--data is empty"
  fi

  for item in "${raw[@]}"; do
    lower=$(printf '%s' "$item" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
      db | database | mysql)
        WANT_DB=1
        DATA_ITEMS+=("db")
        ;;
      files | media | thumbnail | theme | sitemap)
        WANT_VOLUMES+=("$lower")
        DATA_ITEMS+=("$lower")
        ;;
      mysql_data | redis_data)
        die "Refusing volume '${lower}'. Copy the database with --data db (SQL dump), not the ${lower} volume."
        ;;
      *)
        die "Unknown --data item '${item}'. Use db, files, media, thumbnail, theme, sitemap, or all."
        ;;
    esac
  done

  if [[ "$SKIP_DB" -eq 1 ]]; then
    WANT_DB=0
  fi
  if [[ "$SKIP_VOLUMES" -eq 1 ]]; then
    WANT_VOLUMES=()
  fi

  DATA_ITEMS=()
  if [[ "$WANT_DB" -eq 1 ]]; then
    DATA_ITEMS+=("db")
  fi
  local vol
  for vol in "${WANT_VOLUMES[@]+"${WANT_VOLUMES[@]}"}"; do
    DATA_ITEMS+=("$vol")
  done

  if [[ "$WANT_DB" -eq 0 && ${#WANT_VOLUMES[@]} -eq 0 ]]; then
    die "Nothing to do (--data plus --skip-db/--skip-volumes selected an empty set)"
  fi
}

normalize_data "$DATA_SPEC"

lower_s() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

SYNC_ENV_LC="$(lower_s "${SYNC_ENV:-}")"
SHOP_BASE_LC="$(lower_s "$(basename "$COMPOSE_DIR")")"
HOST_SHORT_LC="$(lower_s "$(hostname -s 2>/dev/null || hostname)")"

is_live_consumer() {
  [[ "$SYNC_ENV_LC" == "live" ]] && return 0
  [[ "$SHOP_BASE_LC" == "live" ]] && return 0
  [[ "$HOST_SHORT_LC" == "live" ]] && return 0
  return 1
}

assert_not_live_restore() {
  if is_live_consumer; then
    die "Refusing restore/sync on a live host (SYNC_ENV=${SYNC_ENV:-unset}, checkout=$(basename "$COMPOSE_DIR"), hostname=${HOST_SHORT_LC}). Runtime sync is pull-only onto staging/playground/dev."
  fi
}

alias_key() {
  printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

pick_alias_env() {
  local key=$1
  local suffix=$2
  local specific="SYNC_${key}_${suffix}"
  local general="SYNC_${suffix}"
  if [[ -n "${!specific:-}" ]]; then
    printf '%s' "${!specific}"
  else
    printf '%s' "${!general:-}"
  fi
}

FROM_LC="$(lower_s "$FROM")"

resolve_source() {
  if [[ "$FROM_LC" == "local" || "$FROM_LC" == "this" ]]; then
    SOURCE_IS_LOCAL=1
    FROM="local"
    return
  fi

  SOURCE_IS_LOCAL=0
  local key host user port keyfile specific_dr
  key="$(alias_key "$FROM")"

  host="$(pick_alias_env "$key" SSH_HOST)"
  user="$(pick_alias_env "$key" SSH_USER)"
  port="$(pick_alias_env "$key" SSH_PORT)"
  keyfile="$(pick_alias_env "$key" SSH_KEY)"
  REMOTE_PATH="$(pick_alias_env "$key" REMOTE_PATH)"
  specific_dr="SYNC_${key}_DATA_ROOT"
  REMOTE_DATA_ROOT="${!specific_dr:-${SYNC_REMOTE_DATA_ROOT:-}}"

  if [[ -z "$host" ]]; then
    host=$FROM
  fi
  SYNC_SSH_HOST=$host
  SYNC_SSH_USER=$user
  SYNC_SSH_PORT="${port:-22}"
  SYNC_SSH_KEY=$keyfile

  if [[ -z "${REMOTE_PATH}" ]]; then
    die "SYNC_REMOTE_PATH (or SYNC_${key}_REMOTE_PATH) is required for --from ${FROM}. Set it in deploy/sync.env (see deploy/sync.env.example)."
  fi

  if [[ -n "$SYNC_SSH_USER" ]]; then
    SSH_TARGET="${SYNC_SSH_USER}@${host}"
  else
    SSH_TARGET=$host
  fi
}

resolve_source

SSH_CMD=(ssh -o BatchMode=yes)
if [[ "$SOURCE_IS_LOCAL" -eq 0 ]]; then
  SSH_CMD+=(-p "${SYNC_SSH_PORT:-22}")
  if [[ -n "${SYNC_SSH_KEY:-}" ]]; then
    SSH_CMD+=(-o IdentitiesOnly=yes -i "${SYNC_SSH_KEY}")
  fi
fi

for f in deploy/compose.yaml deploy/compose.prod.yaml deploy/compose.vps.yaml; do
  if [[ ! -f "$f" ]]; then
    die "Missing ${f} (expected under shop root COMPOSE_DIR=${COMPOSE_DIR})"
  fi
done

COMPOSE=(
  docker compose
  -f deploy/compose.yaml
  -f deploy/compose.prod.yaml
  -f deploy/compose.vps.yaml
)

COMPOSE_STR="docker compose -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml"

require_cmd() {
  local c=$1
  if ! command -v "$c" >/dev/null 2>&1; then
    die "Missing command '${c}'. Install docker, bash, openssh-client, gzip, and rsync on this host."
  fi
}

assert_tools() {
  require_cmd bash
  require_cmd gzip
  require_cmd docker
  if ! docker compose version >/dev/null 2>&1; then
    die "docker compose plugin not found. Install Docker Engine + Compose v2."
  fi
  if ! docker info >/dev/null 2>&1; then
    die "Cannot talk to the Docker daemon. Add this user to the docker group or run where the daemon is reachable."
  fi
  if [[ "$SOURCE_IS_LOCAL" -eq 0 ]]; then
    require_cmd ssh
    if [[ -n "${SYNC_SSH_KEY:-}" && ! -f "${SYNC_SSH_KEY}" ]]; then
      die "SYNC_SSH_KEY not found: ${SYNC_SSH_KEY}"
    fi
  fi
  if [[ ${#WANT_VOLUMES[@]} -gt 0 ]] && ! command -v rsync >/dev/null 2>&1; then
    log "rsync not installed; bind-mount trees will use tar (install rsync for incremental live→staging copies)"
  fi
}

# POSIX sh: runs inside the mysql/mariadb container (official images use dash).
mysql_dump_sh() {
  cat <<'EOS'
set -eu
DB="${MYSQL_DATABASE:-shopware}"
if command -v mariadb-dump >/dev/null 2>&1; then
  D=mariadb-dump
elif command -v mysqldump >/dev/null 2>&1; then
  D=mysqldump
else
  echo "Neither mysqldump nor mariadb-dump is in the mysql container" >&2
  exit 1
fi
if command -v mariadb >/dev/null 2>&1; then
  CLI=mariadb
elif command -v mysql >/dev/null 2>&1; then
  CLI=mysql
else
  CLI=""
fi
FLAGS="--single-transaction --quick --routines --triggers --events --hex-blob --no-tablespaces --default-character-set=utf8mb4"
if [ "$D" = mysqldump ]; then
  FLAGS="$FLAGS --column-statistics=0"
fi
# shellcheck disable=SC2086
if [ -n "$CLI" ] && "$CLI" -uroot --protocol=socket -e "SELECT 1" >/dev/null 2>&1; then
  "$D" -uroot --protocol=socket $FLAGS "$DB"
elif [ -n "$CLI" ] && [ -n "${MYSQL_ROOT_PASSWORD:-}" ] && "$CLI" -uroot -p"${MYSQL_ROOT_PASSWORD}" -h127.0.0.1 -e "SELECT 1" >/dev/null 2>&1; then
  "$D" -uroot -p"${MYSQL_ROOT_PASSWORD}" -h127.0.0.1 $FLAGS "$DB"
elif [ -n "$CLI" ] && [ -n "${MYSQL_USER:-}" ] && [ -n "${MYSQL_PASSWORD:-}" ] && "$CLI" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -h127.0.0.1 -e "SELECT 1" >/dev/null 2>&1; then
  "$D" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -h127.0.0.1 $FLAGS "$DB"
else
  "$D" -uroot --protocol=socket $FLAGS "$DB"
fi
EOS
}

mysql_restore_sh() {
  cat <<'EOS'
set -eu
DB="${MYSQL_DATABASE:-shopware}"
if command -v mariadb >/dev/null 2>&1; then
  CLI=mariadb
elif command -v mysql >/dev/null 2>&1; then
  CLI=mysql
else
  echo "Neither mysql nor mariadb client is in the mysql container" >&2
  exit 1
fi
if "$CLI" -uroot --protocol=socket -e "SELECT 1" >/dev/null 2>&1; then
  "$CLI" -uroot --protocol=socket --max-allowed-packet=1G "$DB"
elif [ -n "${MYSQL_ROOT_PASSWORD:-}" ] && "$CLI" -uroot -p"${MYSQL_ROOT_PASSWORD}" -h127.0.0.1 -e "SELECT 1" >/dev/null 2>&1; then
  "$CLI" -uroot -p"${MYSQL_ROOT_PASSWORD}" -h127.0.0.1 --max-allowed-packet=1G "$DB"
elif [ -n "${MYSQL_USER:-}" ] && [ -n "${MYSQL_PASSWORD:-}" ] && "$CLI" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -h127.0.0.1 -e "SELECT 1" >/dev/null 2>&1; then
  "$CLI" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -h127.0.0.1 --max-allowed-packet=1G "$DB"
else
  "$CLI" -uroot --protocol=socket --max-allowed-packet=1G "$DB"
fi
EOS
}

mysql_wait_sh() {
  cat <<'EOS'
set -eu
i=0
while [ "$i" -lt 40 ]; do
  i=$((i + 1))
  if command -v mysqladmin >/dev/null 2>&1 && mysqladmin ping -h 127.0.0.1 --silent; then
    exit 0
  fi
  if command -v mariadb-admin >/dev/null 2>&1 && mariadb-admin ping -h 127.0.0.1 --silent; then
    exit 0
  fi
  sleep 2
done
echo "mysql did not become ready" >&2
exit 1
EOS
}

urldecode() {
  local s=$1
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.argv[1]), end="")' "$s"
    return
  fi
  printf '%b' "${s//%/\\x}"
}

parse_database_url() {
  local url="${DATABASE_URL:-}"
  DB_SCHEME=""
  DB_USER=""
  DB_PASS=""
  DB_HOST=""
  DB_PORT="3306"
  DB_NAME=""
  if [[ -z "$url" ]]; then
    return 1
  fi
  DB_SCHEME="${url%%://*}"
  local rest="${url#*://}"
  rest="${rest%%\?*}"
  local creds hostpart
  if [[ "$rest" == *@* ]]; then
    creds="${rest%%@*}"
    hostpart="${rest#*@}"
  else
    creds=""
    hostpart=$rest
  fi
  if [[ -n "$creds" ]]; then
    DB_USER="${creds%%:*}"
    if [[ "$creds" == *:* ]]; then
      DB_PASS="${creds#*:}"
    fi
    DB_USER="$(urldecode "$DB_USER")"
    DB_PASS="$(urldecode "$DB_PASS")"
  fi
  local hp="${hostpart%%/*}"
  if [[ "$hostpart" == */* ]]; then
    DB_NAME="${hostpart#*/}"
  fi
  DB_NAME="${DB_NAME%%/*}"
  if [[ "$hp" == \[* ]]; then
    DB_HOST="${hp#\[}"
    DB_HOST="${DB_HOST%%]*}"
    local after="${hp#*]}"
    if [[ "$after" == :* ]]; then
      DB_PORT="${after#:}"
    fi
  elif [[ "$hp" == *:* ]]; then
    DB_HOST="${hp%%:*}"
    DB_PORT="${hp#*:}"
  else
    DB_HOST=$hp
  fi
  if [[ -z "$DB_NAME" ]]; then
    DB_NAME="${MYSQL_DATABASE:-shopware}"
  fi
}

has_mysql_service_local() {
  "${COMPOSE[@]}" config --services 2>/dev/null | grep -qx mysql
}

# Pipe a script to remote bash after cd + sourcing the source shop's env files.
# $1 is executed on the remote as-is (no second local expansion).
remote_bash() {
  local payload remote_export
  # Quoted so IMAGE/IMAGE_TAG expand on the remote after it sources .env.
  # shellcheck disable=SC2016
  remote_export='export IMAGE="${IMAGE:-}" IMAGE_TAG="${IMAGE_TAG:-latest}"'
  payload="$(
    printf '%s\n' \
      'set -euo pipefail' \
      "cd $(printf '%q' "$REMOTE_PATH")" \
      'if [[ -f .env ]]; then set -a; source .env; set +a; fi' \
      'if [[ -f .env.prod ]]; then set -a; source .env.prod; set +a; fi' \
      "$remote_export" \
      "$1"
  )"
  printf '%s\n' "$payload" | "${SSH_CMD[@]}" "$SSH_TARGET" bash -s
}

ensure_image_for_compose() {
  if [[ -z "${IMAGE:-}" ]]; then
    die "IMAGE is empty. Set it in shop-root .env (same value deploy/vps-release.sh uses). Sync does not invoke vps-release.sh."
  fi
}

resolve_project_name() {
  local n=""
  if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
    PROJECT_NAME=$COMPOSE_PROJECT_NAME
    return
  fi
  n="$("${COMPOSE[@]}" config 2>/dev/null | awk '/^name:/{print $2; exit}' || true)"
  if [[ -n "$n" ]]; then
    PROJECT_NAME=$n
  else
    PROJECT_NAME="shopware"
  fi
}

resolve_remote_project_name() {
  local n=""
  n="$(remote_bash "${COMPOSE_STR} config 2>/dev/null | awk '/^name:/{print \$2; exit}'" || true)"
  n="$(printf '%s' "$n" | tr -d '\r' | tail -n 1)"
  if [[ -n "$n" ]]; then
    PROJECT_NAME=$n
  else
    resolve_project_name
  fi
}

volume_docker_name() {
  local logical=$1
  printf '%s_%s\n' "$PROJECT_NAME" "$logical"
}

bind_item_dir() {
  local root=$1
  local logical=$2
  printf '%s/%s\n' "$root" "$logical"
}

resolve_remote_data_root() {
  if [[ "$SOURCE_IS_LOCAL" -eq 1 ]]; then
    REMOTE_DATA_ROOT="$DATA_ROOT"
    return
  fi
  if [[ -n "${REMOTE_DATA_ROOT}" ]]; then
    return
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    REMOTE_DATA_ROOT=$DEFAULT_DATA_ROOT
    log "DRY-RUN remote SHOPWARE_DATA_ROOT default ${REMOTE_DATA_ROOT} (probe skipped)"
    return
  fi
  local probed="" remote_printf
  # Expand SYNC_DATA_ROOT / SHOPWARE_DATA_ROOT on the remote after it sources .env.
  # shellcheck disable=SC2016
  remote_printf='printf %s "${SYNC_DATA_ROOT:-${SHOPWARE_DATA_ROOT:-/var/lib/shopware/data}}"'
  probed="$(remote_bash "$remote_printf" || true)"
  probed="$(printf '%s' "$probed" | tr -d '\r' | tail -n 1)"
  if [[ -n "$probed" ]]; then
    REMOTE_DATA_ROOT=$probed
  else
    REMOTE_DATA_ROOT=$DEFAULT_DATA_ROOT
  fi
  log "Remote bind-mount root: ${REMOTE_DATA_ROOT}"
}

chown_data_dir() {
  local d=$1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN chown 82:82 ${d}"
    return
  fi
  mkdir -p "$d"
  if chown -R 82:82 "$d" 2>/dev/null; then
    return
  fi
  docker run --rm -v "${d}:/to" "$ARCHIVE_IMAGE" chown -R 82:82 /to
}

remote_dir_exists() {
  local p=$1
  remote_bash "test -d $(printf '%q' "$p")"
}

rsync_local_trees() {
  local src=$1
  local dest=$2
  mkdir -p "$dest"
  rsync -aH --delete --numeric-ids "${src%/}/" "${dest%/}/"
}

rsync_from_remote_tree() {
  local remote_dir=$1
  local dest=$2
  mkdir -p "$dest"
  rsync -azH --delete --numeric-ids -e "${SSH_CMD[*]}" \
    "${SSH_TARGET}:${remote_dir%/}/" "${dest%/}/"
}

ensure_snapshot_dir() {
  if [[ "$SNAPSHOT_DIR" != /* ]]; then
    SNAPSHOT_DIR="${COMPOSE_DIR}/${SNAPSHOT_DIR}"
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Snapshot directory: ${SNAPSHOT_DIR}"
    return
  fi
    mkdir -p "${SNAPSHOT_DIR}/volumes" "${SNAPSHOT_DIR}/data"
    chmod 700 "$SNAPSHOT_DIR"
}

lock_sync() {
  local lock="${SNAPSHOT_DIR}.lock"
  mkdir -p "$(dirname "$lock")"
  exec 9>"$lock"
  if command -v flock >/dev/null 2>&1; then
    if ! flock -n 9; then
      die "Another sync-runtime.sh run holds ${lock}. Cron overlap — wait or remove a stale lock."
    fi
  fi
}

write_manifest() {
  local dest="${SNAPSHOT_DIR}/MANIFEST.txt"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would write ${dest}"
    return
  fi
  {
    printf 'shopware-runtime-snapshot 1\n'
    printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'source_alias=%s\n' "$FROM"
    printf 'source_local=%s\n' "$SOURCE_IS_LOCAL"
    printf 'source_host=%s\n' "${SYNC_SSH_HOST:-localhost}"
    printf 'consumer_sync_env=%s\n' "${SYNC_ENV:-}"
    printf 'consumer_host=%s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'compose_dir=%s\n' "$COMPOSE_DIR"
    printf 'project=%s\n' "$PROJECT_NAME"
    printf 'data=%s\n' "$(IFS=','; echo "${DATA_ITEMS[*]}")"
    printf 'data_root=%s\n' "$DATA_ROOT"
    printf 'remote_data_root=%s\n' "${REMOTE_DATA_ROOT:-}"
    printf 'transport=ssh+mysqldump+rsync-bind-mounts\n'
    printf 'object_storage=out-of-scope\n'
  } >"$dest"
  if command -v sha256sum >/dev/null 2>&1; then
    (
      cd "$SNAPSHOT_DIR"
      sha256sum db.sql.gz db.sql volumes/*.tar.gz 2>/dev/null || true
    ) >>"$dest"
  fi
}

probe_ssh() {
  if [[ "$SOURCE_IS_LOCAL" -eq 1 ]]; then
    return
  fi
  log "Probing SSH ${SSH_TARGET}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN ${SSH_CMD[*]} ${SSH_TARGET} true"
    return
  fi
  if ! "${SSH_CMD[@]}" -o ConnectTimeout=15 "$SSH_TARGET" true; then
    die "SSH to ${SSH_TARGET} failed (BatchMode, no password prompts). Check SYNC_SSH_HOST/USER/PORT/KEY and known_hosts."
  fi
}

mysql_up_local() {
  if ! has_mysql_service_local; then
    return 1
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would start compose service mysql if needed"
    return 0
  fi
  "${COMPOSE[@]}" up -d --no-build mysql
  "${COMPOSE[@]}" exec -T mysql sh -c "$(mysql_wait_sh)"
}

client_image_for_url() {
  case "${DB_SCHEME:-mysql}" in
    mariadb) printf '%s\n' "${SYNC_MYSQL_CLIENT_IMAGE:-mariadb:11.4}" ;;
    *) printf '%s\n' "${SYNC_MYSQL_CLIENT_IMAGE:-mysql:8.4}" ;;
  esac
}

dump_db_via_url() {
  parse_database_url || die "No bundled mysql service and DATABASE_URL is missing. Set DATABASE_URL or keep the mysql service in deploy/compose.yaml."
  if [[ "$DB_HOST" == "mysql" ]]; then
    die "DATABASE_URL host is 'mysql' but the compose mysql service is not available on the source. Start the stack or point DATABASE_URL at the real database host."
  fi
  local img
  img="$(client_image_for_url)"
  log "Dumping external database ${DB_HOST}:${DB_PORT}/${DB_NAME} via ${img} (credentials from DATABASE_URL, not printed)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN docker run --network host ${img} dump | gzip > ${SNAPSHOT_DIR}/db.sql.gz"
    return
  fi
  docker run --rm --network host --entrypoint sh \
    -e MYSQL_PWD="$DB_PASS" \
    -e DUMP_HOST="$DB_HOST" \
    -e DUMP_PORT="$DB_PORT" \
    -e DUMP_USER="$DB_USER" \
    -e DUMP_DB="$DB_NAME" \
    "$img" \
    -c 'set -eu
      if command -v mariadb-dump >/dev/null; then D=mariadb-dump
      elif command -v mysqldump >/dev/null; then D=mysqldump
      else echo "no dump tool in client image" >&2; exit 1
      fi
      FLAGS="--single-transaction --quick --routines --triggers --events --hex-blob --no-tablespaces --default-character-set=utf8mb4"
      if [ "$D" = mysqldump ]; then FLAGS="$FLAGS --column-statistics=0"; fi
      # shellcheck disable=SC2086
      "$D" -h"$DUMP_HOST" -P"$DUMP_PORT" -u"$DUMP_USER" $FLAGS "$DUMP_DB"' \
    | gzip -c >"${SNAPSHOT_DIR}/db.sql.gz"
  gzip -t "${SNAPSHOT_DIR}/db.sql.gz"
}

dump_db_local() {
  log "Dumping database on this host"
  if has_mysql_service_local; then
    mysql_up_local
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "DRY-RUN ${COMPOSE[*]} exec -T mysql sh -c '<mysqldump|mariadb-dump>' | gzip > ${SNAPSHOT_DIR}/db.sql.gz"
      return
    fi
    "${COMPOSE[@]}" exec -T mysql sh -c "$(mysql_dump_sh)" | gzip -c >"${SNAPSHOT_DIR}/db.sql.gz"
    gzip -t "${SNAPSHOT_DIR}/db.sql.gz"
    return
  fi
  dump_db_via_url
}

dump_db_remote() {
  log "Dumping database on ${SSH_TARGET} (${REMOTE_PATH})"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN ssh ${SSH_TARGET} compose exec mysql dump | gzip → ${SNAPSHOT_DIR}/db.sql.gz"
    return
  fi
  if ! remote_bash "${COMPOSE_STR} config --services 2>/dev/null | grep -qx mysql"; then
    die "Remote has no compose mysql service. A remote DATABASE_URL is not dumped from this host (it may not be reachable). Keep bundled mysql, or snapshot on the source: ssh ${SSH_TARGET} 'cd ${REMOTE_PATH} && bash deploy/sync-runtime.sh snapshot --from local --data db'."
  fi
  local dump_q wait_q
  dump_q=$(printf '%q' "$(mysql_dump_sh)")
  wait_q=$(printf '%q' "$(mysql_wait_sh)")
  remote_bash "${COMPOSE_STR} up -d --no-build mysql
${COMPOSE_STR} exec -T mysql sh -c ${wait_q}
${COMPOSE_STR} exec -T mysql sh -c ${dump_q} | gzip -c" >"${SNAPSHOT_DIR}/db.sql.gz"
  if [[ ! -s "${SNAPSHOT_DIR}/db.sql.gz" ]]; then
    die "Remote database dump produced an empty file"
  fi
  gzip -t "${SNAPSHOT_DIR}/db.sql.gz"
}

restore_db_via_url() {
  parse_database_url || die "No bundled mysql service and DATABASE_URL is missing; cannot restore db."
  if [[ "$DB_HOST" == "mysql" ]]; then
    die "DATABASE_URL host is 'mysql' but the compose mysql service is not running here."
  fi
  local img dump
  img="$(client_image_for_url)"
  if [[ -f "${SNAPSHOT_DIR}/db.sql.gz" ]]; then
    dump="${SNAPSHOT_DIR}/db.sql.gz"
  elif [[ -f "${SNAPSHOT_DIR}/db.sql" ]]; then
    dump="${SNAPSHOT_DIR}/db.sql"
  else
    die "No db.sql.gz (or db.sql) in ${SNAPSHOT_DIR}"
  fi
  log "Restoring external database ${DB_HOST}:${DB_PORT}/${DB_NAME} (credentials from DATABASE_URL, not printed)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN gzip -dc ${dump} | docker run ${img} mysql ${DB_NAME}"
    return
  fi
  local decode=(gzip -dc)
  if [[ "$dump" == *.sql && "$dump" != *.gz ]]; then
    decode=(cat)
  fi
  "${decode[@]}" "$dump" | docker run --rm -i --network host --entrypoint sh \
    -e MYSQL_PWD="$DB_PASS" \
    -e DUMP_HOST="$DB_HOST" \
    -e DUMP_PORT="$DB_PORT" \
    -e DUMP_USER="$DB_USER" \
    -e DUMP_DB="$DB_NAME" \
    "$img" \
    -c 'set -eu
      if command -v mariadb >/dev/null; then C=mariadb; else C=mysql; fi
      "$C" -h"$DUMP_HOST" -P"$DUMP_PORT" -u"$DUMP_USER" --max-allowed-packet=1G "$DUMP_DB"'
}

restore_db_local() {
  local dump=""
  if [[ -f "${SNAPSHOT_DIR}/db.sql.gz" ]]; then
    dump="${SNAPSHOT_DIR}/db.sql.gz"
  elif [[ -f "${SNAPSHOT_DIR}/db.sql" ]]; then
    dump="${SNAPSHOT_DIR}/db.sql"
  else
    die "No db.sql.gz (or db.sql) in ${SNAPSHOT_DIR}"
  fi
  log "Restoring database on this host from ${dump}"
  if has_mysql_service_local; then
    mysql_up_local
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "DRY-RUN gzip -dc ${dump} | ${COMPOSE[*]} exec -T mysql sh -c '<mysql|mariadb>'"
      return
    fi
    if [[ "$dump" == *.gz ]]; then
      gzip -dc "$dump" | "${COMPOSE[@]}" exec -T mysql sh -c "$(mysql_restore_sh)"
    else
      "${COMPOSE[@]}" exec -T mysql sh -c "$(mysql_restore_sh)" <"$dump"
    fi
    return
  fi
  restore_db_via_url
}

archive_volume_local() {
  local logical=$1
  local vol tarout
  vol="$(volume_docker_name "$logical")"
  tarout="${SNAPSHOT_DIR}/volumes/${logical}.tar.gz"
  log "Archiving named volume ${vol} → ${tarout} (bind-mount fallback)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN docker run --rm -v ${vol}:/from:ro -v ${SNAPSHOT_DIR}/volumes:/to ${ARCHIVE_IMAGE} tar"
    return
  fi
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    die "Named volume '${vol}' not found and bind-mount $(bind_item_dir "$DATA_ROOT" "$logical") is missing. mkdir -p \$SHOPWARE_DATA_ROOT/{files,media,thumbnail,theme,sitemap} && chown 82:82 (see deploy/README.md)."
  fi
  docker run --rm \
    -v "${vol}:/from:ro" \
    -v "${SNAPSHOT_DIR}/volumes:/to" \
    "$ARCHIVE_IMAGE" \
    tar -C /from -czf "/to/${logical}.tar.gz" .
  gzip -t "$tarout"
}

archive_volume_remote() {
  local logical=$1
  local vol tarout
  vol="$(volume_docker_name "$logical")"
  tarout="${SNAPSHOT_DIR}/volumes/${logical}.tar.gz"
  log "Archiving remote named volume ${vol} on ${SSH_TARGET} → ${tarout} (bind-mount fallback)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN ssh ${SSH_TARGET} docker run -v ${vol}:/from:ro ${ARCHIVE_IMAGE} tar -czf -"
    return
  fi
  remote_bash "if ! docker volume inspect $(printf '%q' "$vol") >/dev/null 2>&1; then
  echo \"Named volume ${vol} not found on source (project ${PROJECT_NAME}).\" >&2
  exit 1
fi
docker run --rm -v $(printf '%q' "${vol}"):/from:ro $(printf '%q' "$ARCHIVE_IMAGE") tar -C /from -czf - ." >"$tarout"
  if [[ ! -s "$tarout" ]]; then
    die "Remote volume archive for ${logical} was empty"
  fi
  gzip -t "$tarout"
}

restore_volume_local() {
  local logical=$1
  local vol tarin
  vol="$(volume_docker_name "$logical")"
  tarin="${SNAPSHOT_DIR}/volumes/${logical}.tar.gz"
  if [[ ! -f "$tarin" ]]; then
    die "Missing ${tarin}"
  fi
  log "Restoring named volume ${vol} from ${tarin} (bind-mount fallback)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN docker volume create ${vol}; extract tar into ${vol}; chown 82:82"
    return
  fi
  gzip -t "$tarin"
  docker volume create "$vol" >/dev/null
  docker run --rm \
    -v "${vol}:/to" \
    -v "${SNAPSHOT_DIR}/volumes:/from:ro" \
    "$ARCHIVE_IMAGE" \
    sh -c "set -eu
      find /to -mindepth 1 -maxdepth 1 -exec rm -rf {} +
      tar -C /to -xzf /from/${logical}.tar.gz
      chown -R 82:82 /to || true"
}

snapshot_bind_local() {
  local logical=$1
  local src dest
  src="$(bind_item_dir "$DATA_ROOT" "$logical")"
  dest="${SNAPSHOT_DIR}/data/${logical}"
  if [[ -d "$src" ]]; then
    log "Snapshot bind mount ${src} → ${dest}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "DRY-RUN rsync ${src}/ ${dest}/"
      return
    fi
    if command -v rsync >/dev/null 2>&1; then
      rsync_local_trees "$src" "$dest"
    else
      mkdir -p "$dest"
      tar -C "$src" -czf "${SNAPSHOT_DIR}/volumes/${logical}.tar.gz" .
    fi
    return
  fi
  log "Bind mount ${src} missing; trying named volume"
  archive_volume_local "$logical"
}

snapshot_bind_remote() {
  local logical=$1
  local src dest
  src="$(bind_item_dir "$REMOTE_DATA_ROOT" "$logical")"
  dest="${SNAPSHOT_DIR}/data/${logical}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN rsync ${SSH_TARGET}:${src}/ → ${dest}/"
    return
  fi
  if remote_dir_exists "$src"; then
    log "Snapshot remote bind mount ${SSH_TARGET}:${src} → ${dest}"
    if command -v rsync >/dev/null 2>&1; then
      rsync_from_remote_tree "$src" "$dest"
    else
      mkdir -p "$(dirname "${SNAPSHOT_DIR}/volumes/${logical}.tar.gz")"
      remote_bash "docker run --rm -v $(printf '%q' "$src"):/from:ro $(printf '%q' "$ARCHIVE_IMAGE") tar -C /from -czf - ." >"${SNAPSHOT_DIR}/volumes/${logical}.tar.gz"
      gzip -t "${SNAPSHOT_DIR}/volumes/${logical}.tar.gz"
    fi
    return
  fi
  log "Remote bind mount ${src} missing; trying named volume"
  archive_volume_remote "$logical"
}

restore_bind_local() {
  local logical=$1
  local dest snapdir tarin
  dest="$(bind_item_dir "$DATA_ROOT" "$logical")"
  snapdir="${SNAPSHOT_DIR}/data/${logical}"
  tarin="${SNAPSHOT_DIR}/volumes/${logical}.tar.gz"
  if [[ -d "$snapdir" ]]; then
    log "Restoring bind mount ${dest} from ${snapdir}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "DRY-RUN rsync ${snapdir}/ ${dest}/; chown 82:82"
      return
    fi
    mkdir -p "$dest" 2>/dev/null || true
    if command -v rsync >/dev/null 2>&1 && [[ -d "$dest" && -w "$dest" ]] && rsync_local_trees "$snapdir" "$dest"; then
      chown_data_dir "$dest"
    else
      docker run --rm -v "${dest}:/to" -v "${snapdir}:/from:ro" "$ARCHIVE_IMAGE" \
        sh -c 'set -eu; find /to -mindepth 1 -maxdepth 1 -exec rm -rf {} +; cp -a /from/. /to/; chown -R 82:82 /to || true'
    fi
    return
  fi
  if [[ -f "$tarin" ]]; then
    log "Restoring ${dest} from tar ${tarin}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "DRY-RUN extract ${tarin} into ${dest}"
      return
    fi
    mkdir -p "$dest"
    gzip -t "$tarin"
    docker run --rm \
      -v "${dest}:/to" \
      -v "${SNAPSHOT_DIR}/volumes:/from:ro" \
      "$ARCHIVE_IMAGE" \
      sh -c "set -eu
        find /to -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        tar -C /to -xzf /from/${logical}.tar.gz
        chown -R 82:82 /to || true"
    return
  fi
  restore_volume_local "$logical"
}

# Cron path: rsync remote SHOPWARE_DATA_ROOT/<item> → local (no snapshot tree).
sync_bind_from_remote() {
  local logical=$1
  local src dest
  src="$(bind_item_dir "$REMOTE_DATA_ROOT" "$logical")"
  dest="$(bind_item_dir "$DATA_ROOT" "$logical")"
  log "Rsync ${SSH_TARGET}:${src}/ → ${dest}/"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN rsync -az --delete ${SSH_TARGET}:${src}/ ${dest}/; chown 82:82"
    return
  fi
  mkdir -p "$dest" 2>/dev/null || true
  if remote_dir_exists "$src" && command -v rsync >/dev/null 2>&1 && [[ -d "$dest" && -w "$dest" ]]; then
    if rsync_from_remote_tree "$src" "$dest"; then
      chown_data_dir "$dest"
      return
    fi
    log "rsync into ${dest} failed (permissions?); tar via SSH + docker extract"
  fi
  if remote_dir_exists "$src"; then
    remote_bash "docker run --rm -v $(printf '%q' "$src"):/from:ro $(printf '%q' "$ARCHIVE_IMAGE") tar -C /from -czf - ." \
      | docker run --rm -i -v "${dest}:/to" "$ARCHIVE_IMAGE" \
        sh -c 'set -eu; find /to -mindepth 1 -maxdepth 1 -exec rm -rf {} +; tar -C /to -xzf -; chown -R 82:82 /to || true'
    return
  fi
  log "Remote bind mount ${src} missing; named-volume fallback into snapshot then restore"
  archive_volume_remote "$logical"
  restore_bind_local "$logical"
}

stop_app_containers() {
  STOPPED_APP=()
  local svc line
  local -a running=()
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN would stop web/worker/scheduler if running"
    return
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] && running+=("$line")
  done < <("${COMPOSE[@]}" --profile worker --profile scheduler ps --status running --format '{{.Service}}' 2>/dev/null || true)
  for svc in web worker scheduler; do
    local r
    for r in "${running[@]+"${running[@]}"}"; do
      if [[ "$r" == "$svc" ]]; then
        log "Stopping ${svc} for restore"
        "${COMPOSE[@]}" stop "$svc" >/dev/null || "${COMPOSE[@]}" --profile "$svc" stop "$svc" >/dev/null || true
        STOPPED_APP+=("$svc")
      fi
    done
  done
}

start_stopped_app() {
  local svc
  if [[ ${#STOPPED_APP[@]} -eq 0 ]]; then
    return
  fi
  for svc in "${STOPPED_APP[@]}"; do
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "DRY-RUN would start ${svc}"
      continue
    fi
    log "Starting ${svc}"
    case "$svc" in
      web) "${COMPOSE[@]}" up -d --no-build web >/dev/null ;;
      worker) "${COMPOSE[@]}" --profile worker up -d --no-build worker >/dev/null || true ;;
      scheduler) "${COMPOSE[@]}" --profile scheduler up -d --no-build scheduler >/dev/null || true ;;
    esac
  done
}

post_restore_hints() {
  local target="${SYNC_APP_URL:-${APP_URL:-}}"
  log "TODO: rewrite sales-channel domains to this environment (not done automatically)."
  if [[ -n "$target" ]]; then
    log "This shop APP_URL / SYNC_APP_URL=${target} — update sales_channel_domain in admin or SQL after a live pull."
  else
    log "Set SYNC_APP_URL or APP_URL so this reminder shows the destination storefront URL."
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN would try cache:clear (non-fatal) and optional SYNC_POST_RESTORE_CMD"
    return
  fi
  if [[ -n "${IMAGE:-}" ]]; then
    log "Trying cache:clear (non-fatal if the image/console is unavailable)"
    if ! "${COMPOSE[@]}" run --rm --no-build --entrypoint php web bin/console cache:clear; then
      log "cache:clear skipped or failed — not fatal"
    fi
  fi
  if [[ -n "${SYNC_POST_RESTORE_CMD:-}" ]]; then
    log "Running SYNC_POST_RESTORE_CMD (non-fatal)"
    if ! bash -lc "$SYNC_POST_RESTORE_CMD"; then
      log "SYNC_POST_RESTORE_CMD failed — not fatal"
    fi
  fi
}

remote_has_sync_script() {
  remote_bash "test -f deploy/sync-runtime.sh"
}

pull_snapshot_tree() {
  local remote_dir="${SYNC_REMOTE_SNAPSHOT_DIR:-${REMOTE_PATH}/var/runtime-sync}"
  log "Fetching snapshot directory from ${SSH_TARGET}:${remote_dir}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN rsync or tar-over-ssh ${SSH_TARGET}:${remote_dir}/ → ${SNAPSHOT_DIR}/"
    return
  fi
  mkdir -p "$SNAPSHOT_DIR"
  if command -v rsync >/dev/null 2>&1; then
    rsync -az --delete -e "${SSH_CMD[*]}" "${SSH_TARGET}:${remote_dir}/" "${SNAPSHOT_DIR}/"
  else
    log "rsync not installed; using tar over ssh"
    require_cmd tar
    remote_bash "tar -C $(printf '%q' "$remote_dir") -czf - ." | tar -C "$SNAPSHOT_DIR" -xzf -
  fi
}

snapshot_remote_via_script() {
  local remote_dir="${SYNC_REMOTE_SNAPSHOT_DIR:-${REMOTE_PATH}/var/runtime-sync}"
  local data_csv=$1
  log "Running snapshot on ${SSH_TARGET} via deploy/sync-runtime.sh"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN ssh ${SSH_TARGET} bash deploy/sync-runtime.sh snapshot --from local --data ${data_csv} --snapshot-dir ${remote_dir}"
    return
  fi
  remote_bash "bash deploy/sync-runtime.sh snapshot --from local --data $(printf '%q' "$data_csv") --snapshot-dir $(printf '%q' "$remote_dir")"
  pull_snapshot_tree
}

data_csv_effective() {
  local parts=()
  if [[ "$WANT_DB" -eq 1 ]]; then
    parts+=(db)
  fi
  local v
  for v in "${WANT_VOLUMES[@]+"${WANT_VOLUMES[@]}"}"; do
    parts+=("$v")
  done
  local IFS=,
  printf '%s' "${parts[*]}"
}

do_snapshot() {
  ensure_snapshot_dir
  if [[ "$SOURCE_IS_LOCAL" -eq 1 ]]; then
    resolve_project_name
    if [[ "$WANT_DB" -eq 1 ]]; then
      dump_db_local
    fi
    local vol
    for vol in "${WANT_VOLUMES[@]+"${WANT_VOLUMES[@]}"}"; do
      snapshot_bind_local "$vol"
    done
    write_manifest
    log "Snapshot written to ${SNAPSHOT_DIR}"
    return
  fi

  probe_ssh
  resolve_remote_data_root
  local csv
  csv="$(data_csv_effective)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would snapshot from ${SSH_TARGET} (--data ${csv}) bind-mounts under ${REMOTE_DATA_ROOT}"
    resolve_project_name
    if [[ "$WANT_DB" -eq 1 ]]; then
      dump_db_remote
    fi
    local vol
    for vol in "${WANT_VOLUMES[@]+"${WANT_VOLUMES[@]}"}"; do
      snapshot_bind_remote "$vol"
    done
    write_manifest
    return
  fi

  if remote_has_sync_script; then
    snapshot_remote_via_script "$csv"
    log "Snapshot pulled to ${SNAPSHOT_DIR}"
    return
  fi

  log "Remote deploy/sync-runtime.sh not found; streaming dump/rsync over SSH"
  resolve_remote_project_name
  if [[ "$WANT_DB" -eq 1 ]]; then
    dump_db_remote
  fi
  local vol
  for vol in "${WANT_VOLUMES[@]+"${WANT_VOLUMES[@]}"}"; do
    snapshot_bind_remote "$vol"
  done
  write_manifest
  log "Snapshot written to ${SNAPSHOT_DIR}"
}

do_restore() {
  assert_not_live_restore
  ensure_snapshot_dir
  resolve_project_name
  if [[ "$DRY_RUN" -eq 0 && ! -d "$SNAPSHOT_DIR" ]]; then
    die "Snapshot directory not found: ${SNAPSHOT_DIR}"
  fi
  stop_app_containers
  if [[ "$WANT_DB" -eq 1 ]]; then
    restore_db_local
  fi
  local vol
  for vol in "${WANT_VOLUMES[@]+"${WANT_VOLUMES[@]}"}"; do
    restore_bind_local "$vol"
  done
  start_stopped_app
  post_restore_hints
  log "Restore finished into ${COMPOSE_DIR} data_root=${DATA_ROOT} (SYNC_ENV=${SYNC_ENV:-unset})"
}

do_sync() {
  if [[ "$SOURCE_IS_LOCAL" -eq 1 ]]; then
    log "sync --from local snapshots this host then restores the same files (pipeline check). Prefer --from <live-alias> on staging."
    do_snapshot
    do_restore
    return
  fi
  probe_ssh
  resolve_remote_data_root
  resolve_project_name
  stop_app_containers
  if [[ "$WANT_DB" -eq 1 ]]; then
    dump_db_remote
    restore_db_local
  fi
  local vol
  for vol in "${WANT_VOLUMES[@]+"${WANT_VOLUMES[@]}"}"; do
    sync_bind_from_remote "$vol"
  done
  start_stopped_app
  post_restore_hints
  log "Sync finished from ${FROM} → ${DATA_ROOT} (SYNC_ENV=${SYNC_ENV:-unset})"
}

if [[ "$COMMAND" == "restore" || "$COMMAND" == "sync" ]]; then
  assert_not_live_restore
fi

assert_tools
ensure_image_for_compose
ensure_snapshot_dir
lock_sync

log "Runtime data ${COMMAND}  from=${FROM}  data=$(data_csv_effective)  env=${SYNC_ENV:-unset}  data_root=${DATA_ROOT}  dry-run=${DRY_RUN}"
if [[ "$SOURCE_IS_LOCAL" -eq 0 ]]; then
  log "SSH ${SSH_TARGET} port ${SYNC_SSH_PORT:-22}  remote=${REMOTE_PATH}"
fi

case "$COMMAND" in
  snapshot) do_snapshot ;;
  restore) do_restore ;;
  sync) do_sync ;;
  *) die "Unknown command: ${COMMAND}" ;;
esac
