#!/usr/bin/env bash
# Acceptance checks for shopware-cli project dump (sync/backup snapshots).
# Restore stays MySQL/MariaDB client. Rewrite path is unchanged (see sync-rewrite.test.sh).
# No Docker required. Run from anywhere:
#   bash fyrst/shopware-cd/1.0/tests/sync-dump.test.sh

set -euo pipefail

# Env vars below are read by sourced sync_dump_* helpers.
# shellcheck disable=SC2034

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="${ROOT}/root/deploy"
FAILS=0

pass() { printf 'ok  %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

# shellcheck source=../root/deploy/lib/sync-dump.sh
source "$DEPLOY/lib/sync-dump.sh"

echo "==> bash -n / shellcheck dump helpers + sync-runtime"
if bash -n "$DEPLOY/lib/sync-dump.sh"; then
  pass "bash -n sync-dump.sh"
else
  fail "bash -n sync-dump.sh"
fi
if bash -n "$DEPLOY/lib/sync-db.sh"; then
  pass "bash -n sync-db.sh"
else
  fail "bash -n sync-db.sh"
fi
if bash -n "$DEPLOY/sync-runtime.sh"; then
  pass "bash -n sync-runtime.sh"
else
  fail "bash -n sync-runtime.sh"
fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "$DEPLOY/lib/sync-dump.sh" "$DEPLOY/lib/sync-db.sh" "$DEPLOY/sync-runtime.sh"; then
    pass "shellcheck sync-dump.sh + sync-db.sh + sync-runtime.sh"
  else
    fail "shellcheck dump/sync-runtime"
  fi
else
  echo "==> shellcheck not installed (bash -n only)"
fi

echo "==> image pin"
if [[ "$(sync_dump_image)" == "ghcr.io/shopware/shopware-cli:0.18.4" ]]; then
  pass "default pin is ghcr.io/shopware/shopware-cli:0.18.4"
else
  fail "default image is $(sync_dump_image)"
fi
# shellcheck disable=SC2034  # env consumed by sourced sync-dump helpers
SYNC_SHOPWARE_CLI_IMAGE="example.invalid/cli:9"
if [[ "$(sync_dump_image)" == "example.invalid/cli:9" ]]; then
  pass "SYNC_SHOPWARE_CLI_IMAGE overrides the pin"
else
  fail "override image is $(sync_dump_image)"
fi
unset SYNC_SHOPWARE_CLI_IMAGE || true

echo "==> engine defaults + escape hatch"
unset SYNC_DUMP_ENGINE || true
if sync_dump_engine_is_shopware_cli && ! sync_dump_engine_is_mysqldump; then
  pass "default engine is shopware-cli"
else
  fail "default engine is $(sync_dump_engine)"
fi
SYNC_DUMP_ENGINE=mysqldump
if sync_dump_engine_is_mysqldump && ! sync_dump_engine_is_shopware_cli; then
  pass "SYNC_DUMP_ENGINE=mysqldump is the escape hatch"
else
  fail "mysqldump engine detect failed"
fi
unset SYNC_DUMP_ENGINE || true

echo "==> dump flags (clean on, anonymize off, skip-lock-tables, gzip)"
unset SYNC_DUMP_CLEAN SYNC_DUMP_ANONYMIZE SYNC_DUMP_QUICK || true
flags=()
sync_dump_append_project_flags flags "/tmp/db.sql.gz"
joined="${flags[*]}"
if [[ "$joined" == *"--skip-lock-tables"* ]] \
  && [[ "$joined" == *"--compression=gzip"* ]] \
  && [[ "$joined" == *"--output=/tmp/db.sql.gz"* ]] \
  && [[ "$joined" == *"--quick"* ]] \
  && [[ "$joined" == *"--clean"* ]] \
  && [[ "$joined" != *"--anonymize"* ]] \
  && [[ "$joined" == *"project dump"* || "$joined" == *"project"* ]]; then
  pass "default flags: skip-lock-tables, gzip output, --quick, --clean, no --anonymize"
else
  fail "default flags: $joined"
fi
if [[ "$joined" != *"--no-update-hint"* ]]; then
  fail "missing --no-update-hint: $joined"
else
  pass "passes --no-update-hint"
fi

SYNC_DUMP_CLEAN=0
flags=()
sync_dump_append_project_flags flags "/tmp/db.sql.gz"
if [[ "${flags[*]}" == *"--clean"* ]]; then
  fail "SYNC_DUMP_CLEAN=0 must omit --clean (got: ${flags[*]})"
else
  pass "SYNC_DUMP_CLEAN=0 omits --clean"
fi
unset SYNC_DUMP_CLEAN || true

SYNC_DUMP_ANONYMIZE=1
flags=()
sync_dump_append_project_flags flags "/tmp/db.sql.gz"
if [[ "${flags[*]}" == *"--anonymize"* ]]; then
  pass "SYNC_DUMP_ANONYMIZE=1 adds --anonymize"
else
  fail "SYNC_DUMP_ANONYMIZE=1 should add --anonymize: ${flags[*]}"
fi
unset SYNC_DUMP_ANONYMIZE || true

SYNC_DUMP_QUICK=0
flags=()
sync_dump_append_project_flags flags "/tmp/db.sql.gz"
if [[ "${flags[*]}" == *"--quick"* ]]; then
  fail "SYNC_DUMP_QUICK=0 must omit --quick (got: ${flags[*]})"
else
  pass "SYNC_DUMP_QUICK=0 omits --quick"
fi
unset SYNC_DUMP_QUICK || true

echo "==> fail-closed hint"
hint="$(sync_dump_fail_hint)"
if printf '%s' "$hint" | grep -q 'ghcr.io/shopware/shopware-cli:0.18.4' \
  && printf '%s' "$hint" | grep -q 'docker pull' \
  && printf '%s' "$hint" | grep -q 'SYNC_DUMP_ENGINE=mysqldump' \
  && printf '%s' "$hint" | grep -qi 'does not silently fall back'; then
  pass "fail hint names the pin, docker pull, and mysqldump escape hatch"
else
  fail "fail hint incomplete: $hint"
fi

echo "==> dump/restore live in lib/sync-db.sh (entrypoint only dispatches)"
if grep -q 'run_shopware_cli_dump_local' "$DEPLOY/lib/sync-db.sh" \
  && grep -q 'dump_db_local_mysqldump' "$DEPLOY/lib/sync-db.sh" \
  && grep -q 'sync_dump_engine_is_mysqldump' "$DEPLOY/lib/sync-db.sh"; then
  pass "dump_db_local dispatches shopware-cli vs mysqldump escape hatch"
else
  fail "sync-db.sh missing dump engine dispatch"
fi
if grep -A20 '^dump_db_local()' "$DEPLOY/lib/sync-db.sh" | grep -q 'run_shopware_cli_dump_local'; then
  pass "dump_db_local default calls shopware-cli runner"
else
  fail "dump_db_local does not call shopware-cli by default"
fi
if grep -q 'mysql_restore_sh' "$DEPLOY/lib/sync-db.sh" \
  && grep -q 'restore_db_via_url' "$DEPLOY/lib/sync-db.sh"; then
  pass "restore still uses mysql/mariadb client helpers"
else
  fail "restore path lost mysql client import"
fi
if grep -q 'fyrst:sales-channel:rewrite-urls' "$DEPLOY/lib/sync-rewrite.sh" \
  && grep -q 'run --rm --pull never --entrypoint php' "$DEPLOY/lib/sync-rewrite.sh"; then
  pass "sales-channel rewrite path unchanged"
else
  fail "rewrite path changed (must stay fyrst:sales-channel:rewrite-urls via compose run)"
fi
if grep -q 'ghcr.io/shopware/shopware-cli:0.18.4' "$DEPLOY/lib/sync-dump.sh" \
  && grep -q 'ghcr.io/shopware/shopware-cli:0.18.4' "$DEPLOY/sync-runtime.sh"; then
  pass "pin documented in lib + sync-runtime.sh"
else
  fail "pin missing from dump sources"
fi

echo "==> mysqldump is not the default compose-exec path"
if grep -A12 '^dump_db_local()' "$DEPLOY/lib/sync-db.sh" | grep -q 'mysql_dump_sh'; then
  fail "dump_db_local still calls mysql_dump_sh directly"
else
  pass "default dump_db_local does not compose-exec mysqldump"
fi
if grep -A8 '^dump_db_local_mysqldump()' "$DEPLOY/lib/sync-db.sh" | grep -q 'mysql_dump_sh'; then
  pass "mysqldump compose-exec is only on dump_db_local_mysqldump"
else
  fail "escape hatch dump_db_local_mysqldump lost mysql_dump_sh"
fi
# Restore may still exec mysql — that is required.
if grep -q 'gzip -dc "$dump" | "${COMPOSE[@]}" exec -T mysql sh -c "$(mysql_restore_sh)"' "$DEPLOY/lib/sync-db.sh" \
  || grep -q 'mysql_restore_sh' "$DEPLOY/lib/sync-db.sh"; then
  pass "restore still pipes gzip into compose mysql/mariadb"
else
  fail "restore lost gzip | mysql pipe"
fi

echo "==> docs + env examples"
if grep -q 'shopware-cli project dump' "$DEPLOY/sync-runtime.md" \
  && grep -q 'ghcr.io/shopware/shopware-cli:0.18.4' "$DEPLOY/sync-runtime.md" \
  && grep -q 'SYNC_DUMP_CLEAN' "$DEPLOY/sync-runtime.md" \
  && grep -q 'SYNC_DUMP_ANONYMIZE' "$DEPLOY/sync-runtime.md" \
  && grep -q 'SYNC_DUMP_ENGINE=mysqldump' "$DEPLOY/sync-runtime.md"; then
  pass "sync-runtime.md documents shopware-cli dump + flags"
else
  fail "sync-runtime.md missing dump docs"
fi
if grep -q 'shopware-cli project dump' "$DEPLOY/backup-runtime.md" \
  && grep -q 'ghcr.io/shopware/shopware-cli:0.18.4' "$DEPLOY/backup-runtime.md"; then
  pass "backup-runtime.md documents shopware-cli dump"
else
  fail "backup-runtime.md missing dump docs"
fi
if grep -q 'shopware-cli project dump' "$DEPLOY/README.md" \
  && grep -q 'ghcr.io/shopware/shopware-cli:0.18.4' "$DEPLOY/README.md"; then
  pass "deploy README documents shopware-cli dump pin"
else
  fail "deploy README missing dump pin"
fi
if grep -q 'SYNC_DUMP_CLEAN' "$DEPLOY/sync.env.example" \
  && grep -q 'SYNC_DUMP_ANONYMIZE' "$DEPLOY/sync.env.example" \
  && grep -q 'SYNC_DUMP_ENGINE=mysqldump' "$DEPLOY/sync.env.example" \
  && grep -q 'ghcr.io/shopware/shopware-cli:0.18.4' "$DEPLOY/sync.env.example"; then
  pass "sync.env.example has dump env + pin"
else
  fail "sync.env.example missing dump env"
fi
if grep -q 'shopware-cli project dump' "$DEPLOY/backup.env.example"; then
  pass "backup.env.example mentions dump flags"
else
  fail "backup.env.example missing dump flags"
fi

echo "==> backup still calls sync snapshot (not its own dump)"
if grep -q 'sync-runtime.sh" snapshot --from local' "$DEPLOY/backup-runtime.sh"; then
  pass "backup-runtime.sh still reuses sync snapshot"
else
  fail "backup-runtime.sh no longer calls sync snapshot"
fi

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nAll sync-dump checks passed.\n'
