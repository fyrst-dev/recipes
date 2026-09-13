#!/usr/bin/env bash
# Acceptance checks for opt-in sales_channel_domain rewrite.
# Bash keeps requested? + live refuse; rewrite is fyrst:sales-channel:rewrite-urls.
# No Docker required. Run from anywhere:
#   bash fyrst/shopware-cd/1.0/tests/sync-rewrite.test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="${ROOT}/root/deploy"
FAILS=0

pass() { printf 'ok  %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

# shellcheck source=../root/deploy/lib/sync-rewrite.sh
source "$DEPLOY/lib/sync-rewrite.sh"

echo "==> bash -n / shellcheck rewrite helpers"
if bash -n "$DEPLOY/lib/sync-rewrite.sh"; then
  pass "bash -n sync-rewrite.sh"
else
  fail "bash -n sync-rewrite.sh"
fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "$DEPLOY/lib/sync-rewrite.sh"; then
    pass "shellcheck sync-rewrite.sh"
  else
    fail "shellcheck sync-rewrite.sh"
  fi
fi

echo "==> default-off"
unset SYNC_REWRITE_APP_URL SYNC_REWRITE_URL_MAP || true
if sync_rewrite_requested; then
  fail "rewrite must be off when env is unset"
else
  pass "sync_rewrite_requested is false by default"
fi
SYNC_REWRITE_APP_URL="https://staging.example.com"
if sync_rewrite_requested; then
  pass "sync_rewrite_requested is true when SYNC_REWRITE_APP_URL is set"
else
  fail "SYNC_REWRITE_APP_URL should opt in"
fi
unset SYNC_REWRITE_APP_URL || true
SYNC_REWRITE_URL_MAP="https://shop.example.com=https://staging.example.com"
if sync_rewrite_requested; then
  pass "sync_rewrite_requested is true when SYNC_REWRITE_URL_MAP is set"
else
  fail "SYNC_REWRITE_URL_MAP should opt in"
fi
unset SYNC_REWRITE_URL_MAP || true

echo "==> console flag construction (DRY_RUN=1 only)"
SYNC_REWRITE_APP_URL="https://staging.example.com"
unset SYNC_REWRITE_URL_MAP || true
SHOPWARE_DEPLOY_ENV=staging
SYNC_ENV=staging
DRY_RUN=0
args=()
sync_rewrite_append_console_args args "acme-staging"
joined="${args[*]}"
if [[ "$joined" == *"--dry-run"* ]]; then
  fail "DRY_RUN=0 must not pass --dry-run (got: $joined)"
else
  pass "DRY_RUN=0 omits --dry-run"
fi
if [[ "$joined" == *"--app-url=https://staging.example.com"* ]] \
  && [[ "$joined" == *"--deploy-env=staging"* ]] \
  && [[ "$joined" == *"--sync-env=staging"* ]] \
  && [[ "$joined" == *"--checkout-basename=acme-staging"* ]]; then
  pass "passes --app-url / --deploy-env / --sync-env / --checkout-basename"
else
  fail "missing required flags: $joined"
fi
if [[ "$joined" == *"--map="* ]]; then
  fail "must not pass --map when SYNC_REWRITE_URL_MAP is unset (got: $joined)"
else
  pass "omits --map when SYNC_REWRITE_URL_MAP is unset"
fi

DRY_RUN=1
args=()
sync_rewrite_append_console_args args "acme-staging"
if [[ "${args[*]}" == *"--dry-run"* ]]; then
  pass "DRY_RUN=1 adds --dry-run"
else
  fail "DRY_RUN=1 should add --dry-run: ${args[*]}"
fi

unset SYNC_REWRITE_APP_URL || true
SYNC_REWRITE_URL_MAP="https://shop.example.com=https://staging.example.com"
DRY_RUN=0
args=()
sync_rewrite_append_console_args args "acme-staging"
joined="${args[*]}"
if [[ "$joined" == *"--map=https://shop.example.com=https://staging.example.com"* ]] \
  && [[ "$joined" != *"--app-url="* ]]; then
  pass "passes --map only when MAP is set"
else
  fail "map-only flags: $joined"
fi
unset SYNC_REWRITE_URL_MAP || true

echo "==> no bash SQL planner"
if grep -q 'UPDATE sales_channel_domain' "$DEPLOY/lib/sync-rewrite.sh" \
  || grep -q 'sync_rewrite_update_sql' "$DEPLOY/lib/sync-rewrite.sh" \
  || grep -q 'sync_rewrite_plan_from_urls' "$DEPLOY/lib/sync-rewrite.sh"; then
  fail "sync-rewrite.sh still has SQL planner/update helpers"
else
  pass "sync-rewrite.sh has no SQL planner/update helpers"
fi
if grep -q 'UPDATE sales_channel_domain' "$DEPLOY/sync-runtime.sh" \
  || grep -q 'mysql_exec_sql' "$DEPLOY/sync-runtime.sh" \
  || grep -q 'SELECT url FROM sales_channel_domain' "$DEPLOY/sync-runtime.sh"; then
  fail "sync-runtime.sh still has bash SQL updates to sales_channel_domain"
else
  pass "sync-runtime.sh does not UPDATE sales_channel_domain via SQL"
fi
if grep -q 'fyrst:sales-channel:rewrite-urls' "$DEPLOY/sync-runtime.sh" \
  && grep -q 'run --rm --pull never --entrypoint php' "$DEPLOY/sync-runtime.sh"; then
  pass "sync-runtime.sh calls fyrst:sales-channel:rewrite-urls via compose run"
else
  fail "sync-runtime.sh missing compose run of fyrst:sales-channel:rewrite-urls"
fi

echo "==> Flex bundle in manifest.json"
if python3 - "$ROOT/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
bundles = m.get("bundles") or {}
ok = (
    "copy-from-recipe" in m
    and "env" in m
    and bundles.get("Fyrst\\ShopwareCd\\FyrstShopwareCdBundle") == ["all"]
)
raise SystemExit(0 if ok else 1)
PY
then
  pass "manifest.json registers FyrstShopwareCdBundle for all envs"
else
  fail "manifest.json missing Flex bundles entry for FyrstShopwareCdBundle"
fi

echo "==> live refuse helper (SYNC_ALLOW_LIVE_RESTORE does not matter)"
if sync_rewrite_assert_not_live "staging" "staging" "acme-staging" "vps-1" 2>/dev/null; then
  pass "staging consumer may enable rewrite"
else
  fail "staging should allow rewrite"
fi
set +e
out="$(sync_rewrite_assert_not_live "live" "live" "acme-live" "vps-1" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'Refusing sales-channel domain rewrite on a live host'; then
  pass "live consumer cannot enable rewrite"
else
  fail "live rewrite assert rc=$rc out=$out"
fi
set +e
out="$(sync_rewrite_assert_not_live "" "live" "acme-staging" "vps-1" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'SHOPWARE_DEPLOY_ENV=live'; then
  pass "SHOPWARE_DEPLOY_ENV=live refuses rewrite"
else
  fail "deploy-env live rc=$rc out=$out"
fi

echo "==> full script: live + rewrite refuses even with SYNC_ALLOW_LIVE_RESTORE=1"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SHOP="$TMP/acme-live"
mkdir -p "$SHOP/deploy" "$SHOP/var/runtime-sync"
cp "$DEPLOY/compose.yaml" "$DEPLOY/compose.prod.yaml" "$DEPLOY/compose.vps.yaml" "$SHOP/deploy/"
cp -a "$DEPLOY/lib" "$SHOP/deploy/"
cp "$DEPLOY/sync-runtime.sh" "$SHOP/deploy/"
chmod +x "$SHOP/deploy/sync-runtime.sh"
cat >"$SHOP/.env" <<'EOF'
IMAGE=ghcr.io/example/acme
IMAGE_TAG=tag-b
SHOPWARE_SHOP_ID=acme
SHOPWARE_DEPLOY_ENV=live
MYSQL_USER=shop
MYSQL_PASSWORD=shop
MYSQL_ROOT_PASSWORD=root
EOF
: >"$SHOP/.env.prod"
set +e
out="$(cd "$SHOP" && SYNC_REWRITE_APP_URL=https://staging.example.com \
  SYNC_ALLOW_LIVE_RESTORE=1 \
  bash deploy/sync-runtime.sh restore --dry-run --snapshot-dir "$SHOP/var/runtime-sync" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'Refusing sales-channel domain rewrite on a live host'; then
  pass "script refuses rewrite on live even with SYNC_ALLOW_LIVE_RESTORE=1"
else
  fail "live+allow+rewrite rc=$rc out=$out"
fi

echo "==> full script: default-off on live still uses restore guard (no rewrite mention required)"
set +e
out="$(cd "$SHOP" && env -u SYNC_REWRITE_APP_URL -u SYNC_REWRITE_URL_MAP -u SYNC_ALLOW_LIVE_RESTORE \
  bash deploy/sync-runtime.sh restore --dry-run --snapshot-dir "$SHOP/var/runtime-sync" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'Refusing restore/sync on a live host'; then
  pass "default-off live restore still refused (unchanged)"
else
  fail "default live restore rc=$rc out=$out"
fi
if printf '%s' "$out" | grep -q 'sales_channel_domain rewrite'; then
  fail "default-off must not attempt rewrite"
else
  pass "default-off does not attempt rewrite"
fi

echo "==> docs"
if grep -q 'SYNC_REWRITE_APP_URL' "$DEPLOY/sync-runtime.md" \
  && grep -qi 'payment/shipping webhook' "$DEPLOY/sync-runtime.md" \
  && grep -q 'not rewritten unless you opt in' "$DEPLOY/sync-runtime.md" \
  && grep -q 'fyrst:sales-channel:rewrite-urls' "$DEPLOY/sync-runtime.md" \
  && grep -q 'composer update fyrst/shopware-cd' "$DEPLOY/sync-runtime.md"; then
  pass "sync-runtime.md documents opt-in rewrite via console + webhook review"
else
  fail "sync-runtime.md missing rewrite docs"
fi
if grep -q 'SYNC_REWRITE_APP_URL' "$DEPLOY/sync.env.example" \
  && grep -q 'SYNC_REWRITE_URL_MAP' "$DEPLOY/sync.env.example" \
  && grep -q 'fyrst:sales-channel:rewrite-urls' "$DEPLOY/sync.env.example"; then
  pass "sync.env.example has rewrite env + console command"
else
  fail "sync.env.example missing rewrite env"
fi
if grep -q 'FyrstShopwareCdBundle' "$ROOT/post-install.txt" \
  && grep -q 'fyrst:sales-channel:rewrite-urls' "$DEPLOY/README.md"; then
  pass "post-install + deploy README mention bundle / console"
else
  fail "post-install or deploy README missing operator rewrite notes"
fi

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nAll sync-rewrite checks passed.\n'
