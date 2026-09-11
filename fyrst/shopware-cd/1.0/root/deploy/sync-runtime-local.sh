#!/usr/bin/env bash
# Pull live VPS runtime upload trees into a local shopware-cli project dev tree.
#
# Unidirectional: SSH host (default alias "live") → this laptop/checkout.
# Remote bind-mount dirs under SYNC_REMOTE_DATA_ROOT (default
# /var/lib/shopware/data) are remapped to Shopware CLI project paths:
#   media/      → ./public/media/
#   files/      → ./files/
#   thumbnail/  → ./public/thumbnail/
#   theme/      → ./public/theme/
#   sitemap/    → ./public/sitemap/
#
# Does NOT restore the database (dump/import separately).
# Does NOT write to SHOPWARE_DATA_ROOT / SYNC_DATA_ROOT on this machine —
# those are VPS bind-mount roots. Local destinations are always the paths above.
#
# For VPS → VPS (including DB) use deploy/sync-runtime.sh instead.
#
# Required: bash, rsync, ssh (OpenSSH client).
#
# Usage: deploy/sync-runtime-local.sh [options]
# See deploy/README.md and deploy/sync-runtime.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHOP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_FROM="live"
DEFAULT_REMOTE_DATA_ROOT="/var/lib/shopware/data"
DEFAULT_DATA="media,files,thumbnail,theme,sitemap"

FROM="$DEFAULT_FROM"
REMOTE_DATA_ROOT_FLAG=""
DATA_SPEC="all"
DELETE=0
DRY_RUN=0

SSH_TARGET=""
REMOTE_DATA_ROOT=""
DATA_ITEMS=()

log() { printf '==> %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { err "$@"; exit 1; }

usage() {
  cat <<'EOF'
Usage: deploy/sync-runtime-local.sh [options]

Pull runtime uploads from a VPS (default SSH host alias: live) into this
shopware-cli project dev checkout. Does not restore the database.

Options:
  --from <alias>              SSH host alias (default: live). Overridden by
                              SYNC_SSH_HOST when that is set (hostname / Host).
  --data <list>|all           Comma-separated subset, or "all" (default).
                              Items: media,files,thumbnail,theme,sitemap
                              (not db — this script does not copy the database)
  --remote-data-root <path>   Bind-mount root on the SSH source
                              (default: SYNC_REMOTE_DATA_ROOT or
                              /var/lib/shopware/data)
  --delete                    Pass rsync --delete (off by default so extra
                              local files are kept)
  --dry-run                   Print rsync actions; do not copy
  --help                      Show this help

Path remap (remote $REMOTE_DATA_ROOT → local project tree):

  media/      → ./public/media/
  files/      → ./files/
  thumbnail/  → ./public/thumbnail/
  theme/      → ./public/theme/
  sitemap/    → ./public/sitemap/

Environment:
  SYNC_SSH_HOST          SSH hostname (default: --from alias, e.g. Host live)
  SYNC_SSH_USER          SSH user
  SYNC_SSH_PORT          SSH port (default 22)
  SYNC_SSH_KEY           Identity file
  SYNC_REMOTE_DATA_ROOT  Remote bind-mount root
  SYNC_<ALIAS>_SSH_* / SYNC_<ALIAS>_DATA_ROOT
                         Optional per-alias overrides (example: --from live)

Optional: source deploy/sync.env if present (same file as VPS sync).
Local destinations are never SHOPWARE_DATA_ROOT.

Examples:

  bash deploy/sync-runtime-local.sh --dry-run
  bash deploy/sync-runtime-local.sh --from live --data all
  bash deploy/sync-runtime-local.sh --from live --data media,files
  bash deploy/sync-runtime-local.sh --from live --data all --delete

After a successful pull:

  shopware-cli project console cache:clear
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
    help | -h | --help)
      usage
      exit 0
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
    --remote-data-root)
      need_value "$1" "${2:-}"
      REMOTE_DATA_ROOT_FLAG=$2
      shift 2
      ;;
    --remote-data-root=*)
      REMOTE_DATA_ROOT_FLAG="${1#*=}"
      shift
      ;;
    --delete)
      DELETE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
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

if [[ -z "$FROM" ]]; then
  die "--from is empty"
fi

cd "$SHOP_ROOT"

load_env_file() {
  local f=$1
  if [[ -f "$f" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$f"
    set +a
  fi
}

# SSH / remote-root only. Do not use shop-root .env SHOPWARE_DATA_ROOT as dest.
load_env_file deploy/sync.env

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

  DATA_ITEMS=()
  for item in "${raw[@]}"; do
    lower=$(printf '%s' "$item" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
      media | files | thumbnail | theme | sitemap)
        DATA_ITEMS+=("$lower")
        ;;
      db | database | mysql)
        die "This script does not restore the database (refusing --data '${item}'). Dump/import SQL separately. VPS DB pull: deploy/sync-runtime.sh. Local dest is the project dev tree, not SHOPWARE_DATA_ROOT."
        ;;
      mysql_data | redis_data)
        die "Refusing '${lower}'. This script only rsyncs media/files/thumbnail/theme/sitemap into the project dev tree."
        ;;
      *)
        die "Unknown --data item '${item}'. Use media, files, thumbnail, theme, sitemap, or all."
        ;;
    esac
  done

  if [[ ${#DATA_ITEMS[@]} -eq 0 ]]; then
    die "Nothing to do (--data selected an empty set)"
  fi
}

normalize_data "$DATA_SPEC"

lower_s() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

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

local_dest() {
  local logical=$1
  case "$logical" in
    media) printf '%s/public/media\n' "$SHOP_ROOT" ;;
    files) printf '%s/files\n' "$SHOP_ROOT" ;;
    thumbnail) printf '%s/public/thumbnail\n' "$SHOP_ROOT" ;;
    theme) printf '%s/public/theme\n' "$SHOP_ROOT" ;;
    sitemap) printf '%s/public/sitemap\n' "$SHOP_ROOT" ;;
    *) die "No local project dev path for '${logical}'" ;;
  esac
}

remote_src() {
  local logical=$1
  printf '%s/%s\n' "$REMOTE_DATA_ROOT" "$logical"
}

require_cmd() {
  local c=$1
  if ! command -v "$c" >/dev/null 2>&1; then
    die "Missing command '${c}'. Install rsync and an OpenSSH client (ssh)."
  fi
}

require_cmd rsync
require_cmd ssh

KEY="$(alias_key "$FROM")"

host="$(pick_alias_env "$KEY" SSH_HOST)"
user="$(pick_alias_env "$KEY" SSH_USER)"
port="$(pick_alias_env "$KEY" SSH_PORT)"
keyfile="$(pick_alias_env "$KEY" SSH_KEY)"
specific_dr="SYNC_${KEY}_DATA_ROOT"

if [[ -z "$host" ]]; then
  host=$FROM
fi

SYNC_SSH_HOST=$host
SYNC_SSH_USER=$user
SYNC_SSH_PORT="${port:-22}"
SYNC_SSH_KEY=$keyfile

if [[ -n "$REMOTE_DATA_ROOT_FLAG" ]]; then
  REMOTE_DATA_ROOT=$REMOTE_DATA_ROOT_FLAG
else
  REMOTE_DATA_ROOT="${!specific_dr:-${SYNC_REMOTE_DATA_ROOT:-$DEFAULT_REMOTE_DATA_ROOT}}"
fi

if [[ -z "$REMOTE_DATA_ROOT" ]]; then
  die "Remote data root is empty"
fi

if [[ -n "$SYNC_SSH_USER" ]]; then
  SSH_TARGET="${SYNC_SSH_USER}@${SYNC_SSH_HOST}"
else
  SSH_TARGET=$SYNC_SSH_HOST
fi

SSH_CMD=(ssh -o BatchMode=yes -p "${SYNC_SSH_PORT:-22}")
if [[ -n "${SYNC_SSH_KEY:-}" ]]; then
  if [[ ! -f "${SYNC_SSH_KEY}" ]]; then
    die "SYNC_SSH_KEY not found: ${SYNC_SSH_KEY}"
  fi
  SSH_CMD+=(-o IdentitiesOnly=yes -i "${SYNC_SSH_KEY}")
fi

rsync_remote_shell() {
  local out="" a
  for a in "${SSH_CMD[@]}"; do
    out+=" $(printf '%q' "$a")"
  done
  printf '%s' "${out# }"
}

warn_if_live_checkout() {
  local base
  base="$(lower_s "$(basename "$SHOP_ROOT")")"
  if [[ "$base" == "live" ]]; then
    warn "checkout directory is named 'live'. This script writes into local shopware-cli project dev paths (./public/media, ./files, …), not VPS SHOPWARE_DATA_ROOT. For VPS staging pull use deploy/sync-runtime.sh — not this script."
  fi
}

warn_if_live_checkout

if [[ ! -d "${SHOP_ROOT}/public" && ! -f "${SHOP_ROOT}/composer.json" ]]; then
  die "Expected a shopware-cli project root (public/ or composer.json) at ${SHOP_ROOT}. Run from the shop root (or keep this script in deploy/)."
fi

data_csv() {
  local IFS=,
  printf '%s' "${DATA_ITEMS[*]}"
}

log "Live → local project dev rsync  from=${FROM}  host=${SSH_TARGET}  data=$(data_csv)  remote-data-root=${REMOTE_DATA_ROOT}  delete=${DELETE}  dry-run=${DRY_RUN}"
log "Local destinations are project-tree paths (not SHOPWARE_DATA_ROOT)"

if [[ "$DRY_RUN" -eq 0 ]]; then
  log "Probing SSH ${SSH_TARGET}"
  if ! "${SSH_CMD[@]}" -o ConnectTimeout=15 "$SSH_TARGET" true; then
    die "SSH to ${SSH_TARGET} failed (BatchMode, no password prompts). Check Host ${FROM} in ~/.ssh/config, SYNC_SSH_HOST/USER/PORT/KEY, and known_hosts."
  fi
else
  log "DRY-RUN skip SSH probe ${SSH_CMD[*]} ${SSH_TARGET}"
fi

RSYNC_RSH="$(rsync_remote_shell)"
# Omit --numeric-ids so files are owned by the local user, not VPS uid 82.
RSYNC_OPTS=(-azH)
if [[ "$DELETE" -eq 1 ]]; then
  RSYNC_OPTS+=(--delete)
fi

sync_item() {
  local logical=$1
  local src dest
  src="$(remote_src "$logical")"
  dest="$(local_dest "$logical")"

  log "Rsync ${SSH_TARGET}:${src}/ → ${dest}/"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN rsync ${RSYNC_OPTS[*]} -e '${RSYNC_RSH}' ${SSH_TARGET}:${src}/ ${dest}/"
    return
  fi

  mkdir -p "$dest"
  rsync "${RSYNC_OPTS[@]}" -e "$RSYNC_RSH" \
    "${SSH_TARGET}:${src%/}/" "${dest%/}/"
}

for item in "${DATA_ITEMS[@]}"; do
  sync_item "$item"
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY-RUN finished (no files copied, database not touched)"
  log "Reminder: shopware-cli project console cache:clear"
  exit 0
fi

log "Pull finished into ${SHOP_ROOT} (database not restored)"
log "Reminder: shopware-cli project console cache:clear"
