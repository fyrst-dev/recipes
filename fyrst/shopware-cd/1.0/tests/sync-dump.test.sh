#!/usr/bin/env bash
# Dump stays shopware-cli. Recipe and fyrst-cli must not dump or wrap dump.
#   bash fyrst/shopware-cd/1.0/tests/sync-dump.test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=fixtures.sh
source "$(dirname "$0")/fixtures.sh"
FAILS=0

pass() { printf 'ok  %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

echo "==> no dump implementation in this recipe"
if [[ -e "$ROOT/root" || -d "$ROOT/deploy" ]] || compgen -G "$ROOT/*.sh" >/dev/null; then
  fail "recipe still ships root/, deploy/, or shell wrappers"
else
  pass "no overlay tree or shell wrappers"
fi

echo "==> docs: dump is shopware-cli forever"
for f in "$ROOT/README.md" "$ROOT/post-install.txt"
do
  if grep -q 'shopware-cli project dump' "$f"; then
    pass "$(basename "$f") mentions shopware-cli project dump"
  else
    fail "$(basename "$f") missing shopware-cli project dump"
  fi
done
if grep -q 'never dumps' "$ROOT/post-install.txt"; then
  pass "post-install says fyrst-cli never dumps"
else
  fail "docs missing never-dumps wording"
fi
if grep -q 'SYNC_DUMP_ENGINE' "$ROOT/post-install.txt" "$ROOT/README.md"; then
  fail "recipe docs still document SYNC_DUMP_ENGINE as consumed"
else
  pass "recipe docs do not ship dump-engine knobs"
fi

echo "==> capture --data db is not a dump wrap"
if command -v fyrst-cli >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  SHOP="$TMP/acme-staging"
  write_stub_compose "$SHOP"
  cat >"$SHOP/.env" <<'EOF'
IMAGE=ghcr.io/example/acme
IMAGE_TAG=tag-b
SHOPWARE_SHOP_ID=acme
SHOPWARE_DEPLOY_ENV=staging
EOF
  set +e
  out="$(cd "$SHOP" && fyrst-cli shopware sync capture --from local --data db --dry-run 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -eq 2 ]] && printf '%s' "$out" | grep -q 'shopware-cli project dump' \
    && ! printf '%s' "$out" | grep -q 'docker run'; then
    pass "capture --data db exits 2 and points at shopware-cli (no docker run)"
  else
    fail "capture --data db rc=$rc out=$out"
  fi
else
  echo "==> skipping capture --data db (fyrst-cli not installed)"
fi

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nAll sync-dump ownership checks passed.\n'
