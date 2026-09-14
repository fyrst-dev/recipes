#!/usr/bin/env bash
# Shared locator for deploy/lib/dispatch.sh (sourced by the six filename stubs).
# Implementation lives in fyrst-cli 0.1.0+ (https://github.com/fyrst-dev/cli).
# Dump stays shopware-cli; this helper never dumps.
#
# Caller must set SCRIPT_DIR to the deploy/ directory (parent of lib/).

fyrst_cli_refuse_xtrace() {
  case "$-" in
    *x*)
      printf 'ERROR: refusing to run with xtrace (credentials may be in the environment)\n' >&2
      exit 1
      ;;
  esac
}

fyrst_cli_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

fyrst_cli_require() {
  local bin="${FYRST_CLI:-}"
  if [[ -n "$bin" ]]; then
    if [[ -x "$bin" ]]; then
      printf '%s' "$bin"
      return
    fi
    if command -v "$bin" >/dev/null 2>&1; then
      command -v "$bin"
      return
    fi
    fyrst_cli_die "FYRST_CLI=${bin} is not executable. Install fyrst-cli 0.1.0+ or point FYRST_CLI at the binary."
  fi
  if command -v fyrst-cli >/dev/null 2>&1; then
    command -v fyrst-cli
    return
  fi
  printf 'ERROR: fyrst-cli is required (0.1.0+). VPS/laptop install:\n' >&2
  printf '  curl -fsSL https://raw.githubusercontent.com/fyrst-dev/cli/main/scripts/install.sh | bash\n' >&2
  printf '  # pin: FYRST_CLI_VERSION=0.1.0 curl -fsSL https://raw.githubusercontent.com/fyrst-dev/cli/main/scripts/install.sh | bash\n' >&2
  printf 'Or set FYRST_CLI to the binary path.\n' >&2
  exit 1
}

fyrst_cli_shop_root() {
  if [[ -n "${COMPOSE_DIR:-}" ]]; then
    printf '%s' "$COMPOSE_DIR"
    return
  fi
  if [[ -z "${SCRIPT_DIR:-}" ]]; then
    fyrst_cli_die "SCRIPT_DIR is unset (stub must set it before sourcing lib/dispatch.sh)"
  fi
  (cd "${SCRIPT_DIR}/.." && pwd)
}

# Exec fyrst-cli from the shop root. Remaining args are the CLI argv
# after the binary name (e.g. shopware deploy release --dry-run).
fyrst_cli_exec() {
  local bin shop
  bin="$(fyrst_cli_require)"
  shop="$(fyrst_cli_shop_root)"
  if [[ "$shop" != /* ]]; then
    shop="$(cd "$shop" && pwd)" || fyrst_cli_die "Cannot cd to COMPOSE_DIR=${shop}"
  fi
  export COMPOSE_DIR="$shop"
  cd "$shop" || fyrst_cli_die "Cannot cd to COMPOSE_DIR=${shop}"
  exec "$bin" "$@"
}
