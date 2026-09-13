#!/usr/bin/env bash
# Lib-level + CLI checks for the slim sync-runtime dispatcher (#21).
# No live VPS required. Docker is mocked when the daemon is unavailable.
#   bash fyrst/shopware-cd/1.0/tests/sync-runtime.test.sh

set -euo pipefail

# Env vars below are read by sourced helpers.
# shellcheck disable=SC2034

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="${ROOT}/root/deploy"
FAILS=0

pass() { printf 'ok  %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

echo "==> bash -n / shellcheck libs + entrypoint"
for s in "$DEPLOY"/lib/*.sh "$DEPLOY/sync-runtime.sh"; do
  if bash -n "$s"; then
    pass "bash -n $(basename "$s")"
  else
    fail "bash -n $(basename "$s")"
  fi
done
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "$DEPLOY/sync-runtime.sh" "$DEPLOY"/lib/*.sh; then
    pass "shellcheck sync-runtime + deploy/lib"
  else
    fail "shellcheck sync-runtime + deploy/lib"
  fi
else
  echo "==> shellcheck not installed (bash -n only)"
fi

echo "==> entrypoint is a thin dispatcher"
if grep -q 'source "${SCRIPT_DIR}/lib/sync.sh"' "$DEPLOY/sync-runtime.sh" \
  && grep -q 'sync_bootstrap' "$DEPLOY/sync-runtime.sh" \
  && grep -q 'snapshot) do_snapshot' "$DEPLOY/sync-runtime.sh" \
  && ! grep -q '^dump_db_local()' "$DEPLOY/sync-runtime.sh" \
  && ! grep -q '^do_snapshot()' "$DEPLOY/sync-runtime.sh"; then
  pass "sync-runtime.sh sources lib/sync.sh and dispatches"
else
  fail "sync-runtime.sh is not a thin dispatcher"
fi
lines="$(wc -l <"$DEPLOY/sync-runtime.sh")"
if [[ "$lines" -lt 400 ]]; then
  pass "entrypoint is ${lines} lines (was a kitchen-sink script)"
else
  fail "entrypoint still too large (${lines} lines)"
fi

# shellcheck source=../root/deploy/lib/sync.sh
SCRIPT_DIR="$DEPLOY"
source "$DEPLOY/lib/sync.sh"
sync_cli_defaults

echo "==> identity / SoT derive"
SHOPWARE_DATA_BASE=/var/lib/shopware/data
got="$(identity_derived_data_root acme staging)"
if [[ "$got" == "/var/lib/shopware/data/acme/staging" ]]; then
  pass "identity_derived_data_root acme/staging"
else
  fail "derived data root is ${got}"
fi
got="$(identity_derived_project_name acme live)"
if [[ "$got" == "acme-live" ]]; then
  pass "identity_derived_project_name acme-live"
else
  fail "derived project is ${got}"
fi

unset SHOPWARE_DATA_ROOT SYNC_DATA_ROOT PRESET_SYNC_DATA_ROOT || true
SHOPWARE_SHOP_ID=acme
SHOPWARE_DEPLOY_ENV=staging
DATA_ROOT=""
derive_local_data_root
if [[ "$DATA_ROOT" == "/var/lib/shopware/data/acme/staging" ]]; then
  pass "derive_local_data_root from shop id + env"
else
  fail "DATA_ROOT is ${DATA_ROOT}"
fi

PRESET_SYNC_DATA_ROOT=/tmp/custom-sync-root
DATA_ROOT=""
derive_local_data_root
if [[ "$DATA_ROOT" == "/tmp/custom-sync-root" ]]; then
  pass "PRESET_SYNC_DATA_ROOT wins over derived path"
else
  fail "preset override DATA_ROOT=${DATA_ROOT}"
fi
unset PRESET_SYNC_DATA_ROOT SHOPWARE_DATA_ROOT || true

set +e
out="$(SHOPWARE_SHOP_ID= require_shop_id 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'SHOPWARE_SHOP_ID is required'; then
  pass "require_shop_id refuses empty shop id"
else
  fail "require_shop_id rc=$rc out=$out"
fi

echo "==> live restore refuse (lib)"
COMPOSE_DIR="/opt/shopware/acme-staging"
SYNC_ENV=staging
SHOPWARE_DEPLOY_ENV=staging
unset SYNC_ALLOW_LIVE_RESTORE || true
sync_refresh_live_consumer
if is_live_consumer; then
  fail "staging checkout should not look live"
else
  pass "staging is not a live consumer"
fi
COMPOSE_DIR="/opt/shopware/acme-live"
SHOPWARE_DEPLOY_ENV=live
SYNC_ENV=live
sync_refresh_live_consumer
if is_live_consumer; then
  pass "SHOPWARE_DEPLOY_ENV=live is a live consumer"
else
  fail "live deploy env should be a live consumer"
fi
set +e
out="$(assert_not_live_restore 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'Refusing restore/sync on a live host'; then
  pass "assert_not_live_restore dies on live"
else
  fail "live restore assert rc=$rc out=$out"
fi
SYNC_ALLOW_LIVE_RESTORE=1
set +e
out="$(assert_not_live_restore 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'SYNC_ALLOW_LIVE_RESTORE=1'; then
  pass "SYNC_ALLOW_LIVE_RESTORE=1 warns and continues"
else
  fail "allow live restore rc=$rc out=$out"
fi
unset SYNC_ALLOW_LIVE_RESTORE || true

echo "==> --data normalize"
SKIP_DB=0
SKIP_VOLUMES=0
normalize_data all
if [[ "$WANT_DB" -eq 1 && "${DATA_ITEMS[*]}" == "db media files thumbnail theme sitemap" ]]; then
  pass "normalize_data all expands default items"
else
  fail "all items: WANT_DB=$WANT_DB items=${DATA_ITEMS[*]}"
fi
set +e
out="$(normalize_data mysql_data 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q "Refusing volume 'mysql_data'"; then
  pass "refuses --data mysql_data"
else
  fail "mysql_data rc=$rc out=$out"
fi
SKIP_DB=1
SKIP_VOLUMES=1
set +e
out="$(normalize_data all 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'Nothing to do'; then
  pass "--skip-db --skip-volumes on all is empty"
else
  fail "empty set rc=$rc out=$out"
fi
SKIP_DB=0
SKIP_VOLUMES=0

echo "==> CLI help / missing command / unknown option"
set +e
out="$(bash "$DEPLOY/sync-runtime.sh" --help 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'snapshot' \
  && printf '%s' "$out" | grep -q -- '--from' \
  && printf '%s' "$out" | grep -q 'SYNC_DUMP_ENGINE'; then
  pass "--help lists commands and dump env"
else
  fail "--help rc=$rc out=$out"
fi
set +e
out="$(bash "$DEPLOY/sync-runtime.sh" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'Missing command'; then
  pass "missing command exits non-zero"
else
  fail "missing command rc=$rc out=$out"
fi
set +e
out="$(bash "$DEPLOY/sync-runtime.sh" snapshot --nope 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'Unknown option'; then
  pass "unknown option exits non-zero"
else
  fail "unknown option rc=$rc out=$out"
fi

echo "==> fixture: live restore still refused (full script, before docker)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LIVE="$TMP/acme-live"
STAGING="$TMP/acme-staging"
for shop in "$LIVE" "$STAGING"; do
  mkdir -p "$shop/deploy" "$shop/var/runtime-sync"
  cp "$DEPLOY/compose.yaml" "$DEPLOY/compose.prod.yaml" "$DEPLOY/compose.vps.yaml" "$shop/deploy/"
  cp -a "$DEPLOY/lib" "$shop/deploy/"
  cp "$DEPLOY/sync-runtime.sh" "$shop/deploy/"
  chmod +x "$shop/deploy/sync-runtime.sh"
  : >"$shop/.env.prod"
done
cat >"$LIVE/.env" <<'EOF'
IMAGE=ghcr.io/example/acme
IMAGE_TAG=tag-b
SHOPWARE_SHOP_ID=acme
SHOPWARE_DEPLOY_ENV=live
MYSQL_USER=shop
MYSQL_PASSWORD=shop
MYSQL_ROOT_PASSWORD=root
EOF
cat >"$STAGING/.env" <<'EOF'
IMAGE=ghcr.io/example/acme
IMAGE_TAG=tag-b
SHOPWARE_SHOP_ID=acme
SHOPWARE_DEPLOY_ENV=staging
SYNC_ENV=staging
MYSQL_USER=shop
MYSQL_PASSWORD=shop
MYSQL_ROOT_PASSWORD=root
EOF
set +e
out="$(cd "$LIVE" && bash deploy/sync-runtime.sh restore --dry-run --snapshot-dir "$LIVE/var/runtime-sync" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'Refusing restore/sync on a live host'; then
  pass "full script restore --dry-run refuses live"
else
  fail "live restore rc=$rc out=$out"
fi

echo "==> fixture: snapshot --dry-run on staging (mock docker if needed)"
MOCK_BIN="$TMP/bin"
mkdir -p "$MOCK_BIN"
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  cat >"$MOCK_BIN/docker" <<'EOF'
#!/bin/sh
if [ "$1" = compose ] && [ "$2" = version ]; then
  echo "Docker Compose version v2.29.0"
  exit 0
fi
if [ "$1" = info ]; then
  exit 0
fi
if [ "$1" = compose ]; then
  for a in "$@"; do
    if [ "$a" = --services ]; then
      echo mysql
      exit 0
    fi
  done
  echo "name: acme-staging"
  exit 0
fi
if [ "$1" = image ] && [ "$2" = inspect ]; then
  exit 0
fi
exit 0
EOF
  chmod +x "$MOCK_BIN/docker"
  export PATH="$MOCK_BIN:$PATH"
  pass "using mock docker for dry-run (no daemon)"
fi
set +e
out="$(cd "$STAGING" && bash deploy/sync-runtime.sh snapshot --from local --data db --dry-run --snapshot-dir "$STAGING/var/runtime-sync" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'DRY-RUN' \
  && printf '%s' "$out" | grep -q 'shopware-cli' \
  && printf '%s' "$out" | grep -qv 'Refusing'; then
  pass "snapshot --dry-run --from local --data db exits 0 on staging"
else
  fail "staging snapshot dry-run rc=$rc out=$out"
fi

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nAll sync-runtime checks passed.\n'
