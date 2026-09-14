#!/usr/bin/env bash
# Filename stub. Dispatch: fyrst-cli shopware deploy rollback.
#   IMAGE_TAG=$(cat .previous-tag) bash deploy/vps-rollback.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/dispatch.sh
source "${SCRIPT_DIR}/lib/dispatch.sh"
dispatch vps-rollback "$@"
