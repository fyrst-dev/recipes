#!/usr/bin/env bash
# Filename stub. Dispatch: fyrst-cli shopware sync local
# (--data all dropped; CLI default is volumes-only).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/dispatch.sh
source "${SCRIPT_DIR}/lib/dispatch.sh"
dispatch sync-runtime-local "$@"
