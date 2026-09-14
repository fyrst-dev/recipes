#!/usr/bin/env bash
# Rewrite stays fyrst:sales-channel:rewrite-urls (shopware-cd package).
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

echo "==> docs keep APP_URL rewrite + live refuse"
for needle in \
  'APP_URL' \
  'fyrst:sales-channel:rewrite-urls' \
  'FyrstShopwareCdBundle'
do
  if grep -q "$needle" "$ROOT/post-install.txt" \
    || grep -q "$needle" "$ROOT/README.md"; then
    pass "docs mention ${needle}"
  else
    fail "docs missing ${needle}"
  fi
done

if grep -q 'FyrstShopwareCdBundle' "$ROOT/post-install.txt" \
  && grep -q 'fyrst:sales-channel:rewrite-urls' "$ROOT/post-install.txt"; then
  pass "post-install still points at the console command"
else
  fail "post-install dropped rewrite command"
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
