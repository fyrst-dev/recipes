#!/usr/bin/env bash
# Filename stub (CI still runs: bash ./deploy/vps-release.sh).
# Dispatch: fyrst-cli shopware deploy release.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/dispatch.sh
source "${SCRIPT_DIR}/lib/dispatch.sh"
dispatch vps-release "$@"
