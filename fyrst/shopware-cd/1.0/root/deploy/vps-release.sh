#!/usr/bin/env bash
# Run on the VPS (or via SSH from CI) after the image has been pushed.
# Thin wrapper: fyrst-cli shopware deploy release (0.1.0+).
# Never builds the image, never compiles themes/assets, never dumps.
#
# CI still invokes: bash ./deploy/vps-release.sh
# VPS must have fyrst-cli 0.1.0+ on PATH (see deploy/README.md).
#
# Same flags as the CLI: --dry-run, --skip-pull.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/fyrst-cli.sh
source "${SCRIPT_DIR}/lib/fyrst-cli.sh"

fyrst_cli_exec shopware deploy release "$@"
