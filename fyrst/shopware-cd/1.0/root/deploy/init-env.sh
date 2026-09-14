#!/usr/bin/env bash
# Filename stub (CI/operators). Dispatch: fyrst-cli shopware env init.
# Usage: bash deploy/init-env.sh --shop-id <slug> […]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/dispatch.sh
source "${SCRIPT_DIR}/lib/dispatch.sh"
dispatch init-env "$@"
