#!/usr/bin/env bash
# Docs + fyrst-cli checks for shopware sync (lifecycle verbs).
#   bash fyrst/shopware-cd/1.0/tests/sync-runtime.test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="${ROOT}/root/deploy"
FAILS=0

pass() { printf 'ok  %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

if ! command -v fyrst-cli >/dev/null 2>&1; then
  printf 'FAIL fyrst-cli 0.1.0+ is required. Install:\n' >&2
  printf '  curl -fsSL https://raw.githubusercontent.com/fyrst-dev/cli/main/scripts/install.sh | bash\n' >&2
  exit 1
fi

echo "==> docs keep cron + dump ownership"
if grep -q 'fyrst-cli shopware sync pull --from live --data all' "$DEPLOY/sync-runtime.md" \
  && grep -q 'shopware-cli project dump' "$DEPLOY/sync-runtime.md" \
  && grep -q 'fyrst-cli never dumps' "$DEPLOY/sync-runtime.md"; then
  pass "sync-runtime.md documents fyrst-cli cron + shopware-cli dump"
else
  fail "sync-runtime.md missing fyrst-cli/dump contract"
fi
if grep -q 'fyrst-cli shopware sync' "$DEPLOY/sync-runtime.md"; then
  pass "sync-runtime.md names fyrst-cli verbs"
else
  fail "sync-runtime.md missing fyrst-cli verb map"
fi
if grep -q 'bash deploy/sync-runtime.sh' "$DEPLOY/sync-runtime.md"; then
  fail "sync-runtime.md still documents bash deploy/sync-runtime.sh"
else
  pass "sync-runtime.md does not use overlay script names as the operator path"
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
mkdir -p "$SHOP/deploy" "$SHOP/var/runtime-sync"
cp "$DEPLOY/compose.yaml" "$DEPLOY/compose.prod.yaml" "$DEPLOY/compose.vps.yaml" "$SHOP/deploy/"
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
