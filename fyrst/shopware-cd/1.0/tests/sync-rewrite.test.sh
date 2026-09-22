#!/usr/bin/env bash
# Sync runs Shopware sales-channel:update:domain (host from APP_URL). Skipped on live.
# Recipe does not rewrite in bash; fyrst-cli shopware sync apply owns the path.
#   bash fyrst/shopware-cd/1.0/tests/sync-rewrite.test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILS=0

pass() { printf 'ok  %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

echo "==> no bash rewrite helper in this recipe"
if [[ -e "$ROOT/root/deploy/lib/sync-rewrite.sh" || -e "$ROOT/deploy/lib/sync-rewrite.sh" ]]; then
  fail "lib/sync-rewrite.sh should have been removed"
else
  pass "lib/sync-rewrite.sh is gone"
fi

echo "==> docs keep native domain update + empty bundle"
for needle in \
  'APP_URL' \
  'sales-channel:update:domain' \
  'FyrstShopwareCdBundle'
do
  if grep -q "$needle" "$ROOT/post-install.txt" \
    || grep -q "$needle" "$ROOT/README.md"; then
    pass "docs mention ${needle}"
  else
    fail "docs missing ${needle}"
  fi
done

if grep -q 'fyrst:sales-channel:rewrite-urls' "$ROOT/post-install.txt" \
  || grep -q 'fyrst:sales-channel:rewrite-urls' "$ROOT/README.md"; then
  fail "docs still name fyrst:sales-channel:rewrite-urls"
elif grep -q 'sales-channel:update:domain' "$ROOT/post-install.txt" \
  && grep -q 'sales-channel:update:domain' "$ROOT/README.md" \
  && grep -q 'Skipped on live' "$ROOT/post-install.txt" \
  && grep -q 'Skipped on live' "$ROOT/README.md"; then
  pass "docs point at sales-channel:update:domain and skip on live"
else
  fail "docs dropped native domain update or live skip"
fi

echo "==> apply is the rewrite path (fyrst-cli)"
if ! command -v fyrst-cli >/dev/null 2>&1; then
  echo "==> skipping apply help (fyrst-cli not installed)"
else
  set +e
  out="$(fyrst-cli shopware sync apply --help 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q -- '--snapshot-dir'; then
    pass "fyrst-cli shopware sync apply --help (rewrite happens in fyrst-cli)"
  else
    fail "sync apply --help rc=$rc out=$out"
  fi
fi

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nAll sync-rewrite docs checks passed.\n'
