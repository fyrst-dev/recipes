#!/usr/bin/env bash
# Filename stub (cron: snapshot|restore|sync). Maps live in lib/dispatch.sh.
# Dispatch: fyrst-cli shopware sync {capture|apply|pull}.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/dispatch.sh
source "${SCRIPT_DIR}/lib/dispatch.sh"
dispatch sync-runtime "$@"
