#!/usr/bin/env bash
# Roll the VPS Compose stack back to the tag in .previous-tag.
# Thin wrapper: fyrst-cli shopware deploy rollback (0.1.0+).
# Never builds the image. IMAGE_TAG from the process environment is ignored.
#
# Shop-facing one-liner (CI / operators):
#   IMAGE_TAG=$(cat .previous-tag) bash deploy/vps-rollback.sh
# fyrst-cli prints the equivalent:
#   IMAGE_TAG=$(cat .previous-tag) fyrst-cli shopware deploy rollback
#
# Same flags as the CLI: --dry-run, --skip-pull.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/fyrst-cli.sh
source "${SCRIPT_DIR}/lib/fyrst-cli.sh"

fyrst_cli_exec shopware deploy rollback "$@"
