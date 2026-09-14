#!/usr/bin/env bash
# Backup Shopware runtime (volumes + operator-provided dump) to BACKUP_TARGET.
# Thin wrapper: fyrst-cli shopware backup {create|prune|recover} (0.1.0+).
#
# Overlay verbs stay so existing cron keeps working:
#   backup  → fyrst-cli shopware backup create
#   prune   → fyrst-cli shopware backup prune
#   restore → fyrst-cli shopware backup recover
#
# Dump stays shopware-cli. This wrapper never dumps.
# For --data db, set BACKUP_DB_DUMP to an already-made db.sql.gz.
#
# Usage: deploy/backup-runtime.sh <backup|prune|restore> [options]
# See deploy/backup-runtime.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/fyrst-cli.sh
source "${SCRIPT_DIR}/lib/fyrst-cli.sh"

fyrst_cli_refuse_xtrace

usage() {
  cat <<'EOF'
Usage: deploy/backup-runtime.sh <backup|prune|restore> [options]

Thin wrapper around fyrst-cli 0.1.0+ (install on live).
  backup  | create   → fyrst-cli shopware backup create
  prune              → fyrst-cli shopware backup prune
  restore | recover  → fyrst-cli shopware backup recover

This is not deploy/sync-runtime.sh. Allowed on SHOPWARE_DEPLOY_ENV=live.

Dump is shopware-cli project dump. Set BACKUP_DB_DUMP to an already-made
db.sql.gz when --data includes db (default all).

Flags are passed through: --data, --dry-run, --from / --artifact,
--i-understand-this-restores-this-host.

See deploy/backup-runtime.md and: fyrst-cli shopware backup --help
EOF
}

cmd="${1:-}"
case "$cmd" in
  "")
    usage
    exit 2
    ;;
  help | -h | --help)
    usage
    printf '\n'
    fyrst_cli_exec shopware backup --help
    ;;
  backup | create)
    shift
    fyrst_cli_exec shopware backup create "$@"
    ;;
  prune)
    shift
    fyrst_cli_exec shopware backup prune "$@"
    ;;
  restore | recover)
    shift
    fyrst_cli_exec shopware backup recover "$@"
    ;;
  *)
    fyrst_cli_die "Unknown command: ${cmd} (try --help)"
    ;;
esac
