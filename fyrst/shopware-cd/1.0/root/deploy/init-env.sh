#!/usr/bin/env bash
# Finish shop-root .env after shopware-cli project create + Flex.
# Thin wrapper: fyrst-cli shopware env init (0.1.0+).
# Does not dump. Does not overwrite the whole .env.
#
# Usage (from shop root, or COMPOSE_DIR=shop-root):
#   bash deploy/init-env.sh --shop-id <slug> [--env live] [--vps] …
#
# See deploy/README.md and: fyrst-cli shopware env init --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/fyrst-cli.sh
source "${SCRIPT_DIR}/lib/fyrst-cli.sh"

fyrst_cli_refuse_xtrace
fyrst_cli_exec shopware env init "$@"
