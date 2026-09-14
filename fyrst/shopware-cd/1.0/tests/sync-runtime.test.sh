#!/usr/bin/env bash
# Docs + fyrst-cli checks for shopware sync (lifecycle verbs).
#   bash fyrst/shopware-cd/1.0/tests/sync-runtime.test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=fixtures.sh
source "$(dirname "$0")/fixtures.sh"
FAILS=0

pass() { printf 'ok  %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

require_fyrst_cli

echo "==> recipe docs keep cron + dump ownership"
if grep -q 'fyrst-cli shopware sync pull' "$ROOT/post-install.txt" \
  && grep -q 'shopware-cli project dump' "$ROOT/post-install.txt" \
  && grep -q 'never dumps' "$ROOT/post-install.txt"; then
  pass "post-install documents fyrst-cli sync + shopware-cli dump"
else
  fail "post-install missing fyrst-cli/dump contract"
fi
if grep -q 'bash deploy/sync-runtime.sh' "$ROOT/post-install.txt" \
  || grep -q 'bash deploy/sync-runtime.sh' "$ROOT/README.md"; then
  fail "recipe docs still document bash deploy/sync-runtime.sh"
else
  pass "recipe docs do not use overlay script names as the operator path"
fi

echo "==> fyrst-cli help uses lifecycle verbs"
for cmd in capture apply pull local; do
  set +e
  out="$(fyrst-cli shopware sync "$cmd" --help 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    pass "fyrst-cli shopware sync $cmd --help"
  else
    fail "sync $cmd --help rc=$rc out=$out"
  fi
done

echo "==> live refuse via fyrst-cli shopware sync apply"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SHOP="$TMP/acme-live"
write_stub_compose "$SHOP"
mkdir -p "$SHOP/var/runtime-sync"
cat >"$SHOP/.env" <<'EOF'
IMAGE=ghcr.io/example/acme
IMAGE_TAG=tag-b
SHOPWARE_SHOP_ID=acme
SHOPWARE_DEPLOY_ENV=live
EOF
set +e
out="$(cd "$SHOP" && fyrst-cli shopware sync apply --dry-run --snapshot-dir "$SHOP/var/runtime-sync" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'Refusing restore/sync on a live host'; then
  pass "sync apply refuses live"
else
  fail "live apply rc=$rc out=$out"
fi

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nAll sync-runtime fyrst-cli checks passed.\n'
