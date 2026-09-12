#!/usr/bin/env bash
# Acceptance checks for opt-in sales_channel_domain rewrite (#17).
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

echo "==> default-off (#17)"
unset SYNC_REWRITE_APP_URL SYNC_REWRITE_URL_MAP || true
if sync_rewrite_requested; then
  fail "rewrite must be off when env is unset"
else
  pass "sync_rewrite_requested is false by default"
fi

echo "==> origin replace keeps path"
SYNC_REWRITE_APP_URL="https://staging.example.com"
unset SYNC_REWRITE_URL_MAP || true
sync_rewrite_validate_opts
got="$(sync_rewrite_apply_url "https://shop.example.com/en")"
if [[ "$got" == "https://staging.example.com/en" ]]; then
  pass "https://shop.example.com/en → staging /en"
else
  fail "origin replace got $got"
fi
got="$(sync_rewrite_apply_url "https://shop.example.com")"
if [[ "$got" == "https://staging.example.com" ]]; then
  pass "https://shop.example.com → staging origin"
else
  fail "bare origin got $got"
fi
got="$(sync_rewrite_apply_url "http://shop.example.com:8080/de/")"
if [[ "$got" == "https://staging.example.com/de/" ]]; then
  pass "scheme+port replaced; path kept"
else
  fail "port replace got $got"
fi

echo "==> URL map longest prefix"
unset SYNC_REWRITE_APP_URL || true
SYNC_REWRITE_URL_MAP="https://shop.example.com=https://staging.example.com,https://shop.example.com/en=https://en.staging.example.com,https://b2b.example.com=https://b2b.staging.example.com"
sync_rewrite_validate_opts
got="$(sync_rewrite_apply_url "https://shop.example.com/en/about")"
if [[ "$got" == "https://en.staging.example.com/about" ]]; then
  pass "longest prefix map wins"
else
  fail "map prefix got $got"
fi
got="$(sync_rewrite_apply_url "https://other.example.com")"
if [[ "$got" == "https://other.example.com" ]]; then
  pass "unmapped URL left unchanged when only MAP is set"
else
  fail "unmapped got $got"
fi

echo "==> plan + SQL + collision"
SYNC_REWRITE_APP_URL="https://staging.example.com"
unset SYNC_REWRITE_URL_MAP || true
sync_rewrite_validate_opts
plan="$(printf '%s\n' "https://live.example.com" "https://live.example.com/en" | sync_rewrite_plan_from_urls)"
if printf '%s\n' "$plan" | grep -qx $'https://live.example.com\thttps://staging.example.com' \
  && printf '%s\n' "$plan" | grep -qx $'https://live.example.com/en\thttps://staging.example.com/en'; then
  pass "plan rewrites both live domains to staging"
else
  fail "plan was: $plan"
fi
sql="$(sync_rewrite_update_sql "https://live.example.com/en" "https://staging.example.com/en")"
if printf '%s' "$sql" | grep -q "UPDATE sales_channel_domain" \
  && printf '%s' "$sql" | grep -q "https://staging.example.com/en" \
  && printf '%s' "$sql" | grep -q "WHERE url = 'https://live.example.com/en'"; then
  pass "SQL updates sales_channel_domain.url only"
else
  fail "SQL was: $sql"
fi
if ! printf '%s' "$sql" | grep -qiE 'system_config|media|plugin'; then
  pass "SQL does not touch system_config / media / plugin tables"
else
  fail "SQL escaped the sales_channel_domain-only rule"
fi
set +e
coll_err="$(printf '%s\n' "https://a.example.com/x" "https://b.example.com/x" | sync_rewrite_plan_from_urls 2>&1)"
coll_rc=$?
set -e
if [[ "$coll_rc" -eq 2 ]] && printf '%s' "$coll_err" | grep -qi collision; then
  pass "collision on unique url is refused"
else
  fail "collision rc=$coll_rc err=$coll_err"
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
  && grep -q 'not rewritten unless you opt in' "$DEPLOY/sync-runtime.md"; then
  pass "sync-runtime.md documents opt-in rewrite + webhook review"
else
  fail "sync-runtime.md missing rewrite docs"
fi
if grep -q 'SYNC_REWRITE_APP_URL' "$DEPLOY/sync.env.example" \
  && grep -q 'SYNC_REWRITE_URL_MAP' "$DEPLOY/sync.env.example"; then
  pass "sync.env.example has rewrite env"
else
  fail "sync.env.example missing rewrite env"
fi

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nAll sync-rewrite checks passed.\n'
