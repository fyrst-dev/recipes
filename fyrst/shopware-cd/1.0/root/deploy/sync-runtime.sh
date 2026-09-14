#!/usr/bin/env bash
# Snapshot / restore / sync Shopware runtime data between VPS environments.
# Thin wrapper: fyrst-cli shopware sync {capture|apply|pull} (0.1.0+).
#
# Overlay verbs stay so existing cron keeps working:
#   snapshot → fyrst-cli shopware sync capture
#   restore  → fyrst-cli shopware sync apply
#   sync     → fyrst-cli shopware sync pull
#
# Dump stays shopware-cli project dump. This wrapper never dumps.
# If --data includes db, place db.sql.gz in --snapshot-dir first
# (or import with: fyrst-cli shopware db import --file <path>).
#
# Usage: deploy/sync-runtime.sh <snapshot|restore|sync> [options]
# See deploy/sync-runtime.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/fyrst-cli.sh
source "${SCRIPT_DIR}/lib/fyrst-cli.sh"

fyrst_cli_refuse_xtrace

usage() {
  cat <<'EOF'
Usage: deploy/sync-runtime.sh <snapshot|restore|sync> [options]

Thin wrapper around fyrst-cli 0.1.0+ (install on each VPS).
  snapshot | capture  → fyrst-cli shopware sync capture
  restore  | apply    → fyrst-cli shopware sync apply
  sync     | pull     → fyrst-cli shopware sync pull

Dump is shopware-cli project dump. fyrst-cli never dumps.
If --data includes db, run shopware-cli project dump on the source and
place db.sql.gz in --snapshot-dir (default <shop>/var/runtime-sync).

Flags are passed through: --from, --data, --snapshot-dir, --dry-run,
--skip-db, --skip-volumes.

See deploy/sync-runtime.md and: fyrst-cli shopware sync --help
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
    fyrst_cli_exec shopware sync --help
    ;;
  snapshot | capture)
    shift
    fyrst_cli_exec shopware sync capture "$@"
    ;;
  restore | apply)
    shift
    fyrst_cli_exec shopware sync apply "$@"
    ;;
  sync | pull)
    shift
    fyrst_cli_exec shopware sync pull "$@"
    ;;
  *)
    fyrst_cli_die "Unknown command: ${cmd} (try --help)"
    ;;
esac
