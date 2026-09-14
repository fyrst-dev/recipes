#!/usr/bin/env bash
# Pull live VPS runtime upload trees into a local shopware-cli project dev tree.
# Thin wrapper: fyrst-cli shopware sync local (0.1.0+).
#
# Never restores the database. Never writes SHOPWARE_DATA_ROOT.
# Overlay --data all meant volumes-only; fyrst-cli refuses --data all on
# this verb, so the wrapper drops --data all and uses the CLI default
# (media,files,thumbnail,theme,sitemap).
#
# Usage: deploy/sync-runtime-local.sh [options]
# See deploy/README.md and deploy/sync-runtime.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/fyrst-cli.sh
source "${SCRIPT_DIR}/lib/fyrst-cli.sh"

fyrst_cli_refuse_xtrace

case "${1:-}" in
  help | -h | --help)
    cat <<'EOF'
Usage: deploy/sync-runtime-local.sh [options]

Thin wrapper around fyrst-cli shopware sync local (0.1.0+).
Does not restore the database. Does not write SHOPWARE_DATA_ROOT.

  --from <alias>              SSH host alias (default: live)
  --data <list>               media,files,thumbnail,theme,sitemap
                              --data all is accepted and dropped (CLI default)
  --remote-data-root <path>   Bind-mount root on the SSH source
  --delete                    Pass rsync --delete
  --dry-run                   Print rsync actions; do not copy

Dump/import SQL separately:
  shopware-cli project dump
  fyrst-cli shopware db import --file db.sql.gz

See: fyrst-cli shopware sync local --help
EOF
    printf '\n'
    fyrst_cli_exec shopware sync local --help
    ;;
esac

fyrst_cli_rewrite_sync_local_args "$@"
