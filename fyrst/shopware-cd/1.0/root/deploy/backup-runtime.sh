#!/usr/bin/env bash
# Filename stub (cron: backup|prune|restore). Maps live in lib/dispatch.sh.
# Dispatch: fyrst-cli shopware backup {create|prune|recover}.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/dispatch.sh
source "${SCRIPT_DIR}/lib/dispatch.sh"
dispatch backup-runtime "$@"
