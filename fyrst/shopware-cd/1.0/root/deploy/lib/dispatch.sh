#!/usr/bin/env bash
# Dispatcher for the six deploy/*.sh filename stubs.
# Operator names stay (CI/cron). Maps + local --data all rewrite live here.
# Locator / exec stay in lib/fyrst-cli.sh.
#
# Caller must set SCRIPT_DIR to the deploy/ directory, then:
#   source "${SCRIPT_DIR}/lib/dispatch.sh"
#   dispatch <entrypoint> "$@"

# shellcheck source=fyrst-cli.sh
source "${SCRIPT_DIR}/lib/fyrst-cli.sh"

# Overlay sync-runtime-local.sh treated --data all as volumes-only.
# fyrst-cli shopware sync local refuses --data all (all includes db on
# sync pull / backup create). Drop --data all so the CLI default applies.
dispatch_rewrite_sync_local_args() {
  local -a out=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --data)
        if [[ "${2:-}" == "all" ]]; then
          shift 2
        else
          out+=("$1" "${2:-}")
          shift 2
        fi
        ;;
      --data=all)
        shift
        ;;
      --data=*)
        if [[ "${1#--data=}" == "all" ]]; then
          shift
        else
          out+=("$1")
          shift
        fi
        ;;
      *)
        out+=("$1")
        shift
        ;;
    esac
  done
  if [[ ${#out[@]} -gt 0 ]]; then
    fyrst_cli_exec shopware sync local "${out[@]}"
  else
    fyrst_cli_exec shopware sync local
  fi
}

dispatch() {
  local entry="${1:-}"
  if [[ -z "$entry" ]]; then
    fyrst_cli_die "dispatch requires an entrypoint"
  fi
  shift

  case "$entry" in
    init-env)
      fyrst_cli_refuse_xtrace
      fyrst_cli_exec shopware env init "$@"
      ;;
    vps-release)
      fyrst_cli_exec shopware deploy release "$@"
      ;;
    vps-rollback)
      fyrst_cli_exec shopware deploy rollback "$@"
      ;;
    sync-runtime)
      fyrst_cli_refuse_xtrace
      dispatch_sync_runtime "$@"
      ;;
    sync-runtime-local)
      fyrst_cli_refuse_xtrace
      dispatch_sync_runtime_local "$@"
      ;;
    backup-runtime)
      fyrst_cli_refuse_xtrace
      dispatch_backup_runtime "$@"
      ;;
    *)
      fyrst_cli_die "Unknown deploy entrypoint: ${entry}"
      ;;
  esac
}

dispatch_sync_runtime() {
  local cmd="${1:-}"
  case "$cmd" in
    "")
      printf 'Usage: deploy/sync-runtime.sh <snapshot|restore|sync> [options]\n' >&2
      printf 'See: fyrst-cli shopware sync --help\n' >&2
      exit 2
      ;;
    help | -h | --help)
      fyrst_cli_exec shopware sync --help
      ;;
    snapshot | capture)
      shift
      fyrst_cli_exec shopware sync capture "$@"
      ;;
    restore | apply)
      shift
      fyrst_cli_exec shopware sync apply "$@"
      ;;
    sync | pull)
      shift
      fyrst_cli_exec shopware sync pull "$@"
      ;;
    *)
      fyrst_cli_die "Unknown command: ${cmd} (try --help)"
      ;;
  esac
}

dispatch_sync_runtime_local() {
  case "${1:-}" in
    help | -h | --help)
      fyrst_cli_exec shopware sync local --help
      ;;
  esac
  dispatch_rewrite_sync_local_args "$@"
}

dispatch_backup_runtime() {
  local cmd="${1:-}"
  case "$cmd" in
    "")
      printf 'Usage: deploy/backup-runtime.sh <backup|prune|restore> [options]\n' >&2
      printf 'See: fyrst-cli shopware backup --help\n' >&2
      exit 2
      ;;
    help | -h | --help)
      fyrst_cli_exec shopware backup --help
      ;;
    backup | create)
      shift
      fyrst_cli_exec shopware backup create "$@"
      ;;
    prune)
      shift
      fyrst_cli_exec shopware backup prune "$@"
      ;;
    restore | recover)
      shift
      fyrst_cli_exec shopware backup recover "$@"
      ;;
    *)
      fyrst_cli_die "Unknown command: ${cmd} (try --help)"
      ;;
  esac
}
