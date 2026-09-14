#!/usr/bin/env bash
# Rewrite stays fyrst:sales-channel:rewrite-urls (shopware-cd package).
# Overlay does not rewrite in bash; fyrst-cli shopware sync apply owns the path.
#   bash fyrst/shopware-cd/1.0/tests/sync-rewrite.test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="${ROOT}/root/deploy"
FAILS=0

pass() { printf 'ok  %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

echo "==> no bash rewrite helper"
if [[ -e "$DEPLOY/lib/sync-rewrite.sh" ]]; then
  fail "lib/sync-rewrite.sh should have been removed"
else
  pass "lib/sync-rewrite.sh is gone"
fi

echo "==> docs keep opt-in rewrite + live refuse"
for needle in \
  'SYNC_REWRITE_APP_URL' \
  'SYNC_REWRITE_URL_MAP' \
  'fyrst:sales-channel:rewrite-urls' \
  'impossible on live' \
  'hard-refused'
do
  if grep -q "$needle" "$DEPLOY/sync-runtime.md" \
    || grep -q "$needle" "$DEPLOY/README.md" \
    || grep -q "$needle" "$ROOT/post-install.txt"; then
    pass "docs mention ${needle}"
  else
    fail "docs missing ${needle}"
  fi
done

if grep -q 'SYNC_REWRITE_APP_URL' "$DEPLOY/sync.env.example" \
  && grep -q 'fyrst:sales-channel:rewrite-urls' "$DEPLOY/sync.env.example"; then
  pass "sync.env.example documents opt-in rewrite"
else
  fail "sync.env.example missing rewrite env"
fi

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
