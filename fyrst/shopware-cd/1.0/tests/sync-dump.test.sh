#!/usr/bin/env bash
# Dump stays shopware-cli. Overlay and fyrst-cli must not dump or wrap dump.
#   bash fyrst/shopware-cd/1.0/tests/sync-dump.test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="${ROOT}/root/deploy"
FAILS=0

pass() { printf 'ok  %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

echo "==> no dump implementation in the overlay"
if [[ -e "$DEPLOY/lib/sync-dump.sh" ]]; then
  fail "lib/sync-dump.sh should have been removed"
else
  pass "lib/sync-dump.sh is gone"
fi
if compgen -G "$DEPLOY/*.sh" >/dev/null || [[ -d "$DEPLOY/lib" ]]; then
  fail "deploy still ships shell wrappers"
else
  pass "no overlay shell wrappers"
fi

echo "==> docs: dump is shopware-cli forever"
for f in "$DEPLOY/sync-runtime.md" "$DEPLOY/backup-runtime.md" "$DEPLOY/README.md" \
  "$ROOT/README.md" "$ROOT/post-install.txt"
do
  if grep -q 'shopware-cli project dump' "$f"; then
    pass "$(basename "$f") mentions shopware-cli project dump"
  else
    fail "$(basename "$f") missing shopware-cli project dump"
  fi
done
if grep -q 'fyrst-cli never dumps' "$DEPLOY/sync-runtime.md" \
  && grep -q 'never dumps' "$DEPLOY/backup-runtime.md"; then
  pass "sync/backup docs say fyrst-cli never dumps"
else
  fail "docs missing never-dumps wording"
fi
EXAMPLE="${ROOT}/root/.env.example"
if grep -q 'SYNC_DUMP_ENGINE' "$EXAMPLE"; then
  fail ".env.example still documents SYNC_DUMP_ENGINE as consumed"
else
  pass ".env.example does not ship dump-engine knobs"
fi
if grep -q 'BACKUP_DB_DUMP' "$EXAMPLE"; then
  pass ".env.example documents BACKUP_DB_DUMP"
else
  fail ".env.example missing BACKUP_DB_DUMP"
fi
for s in sync.env.example backup.env.example; do
  if [[ -e "$DEPLOY/$s" ]]; then
    fail "$s should have been removed"
  else
    pass "removed $s"
  fi
done

echo "==> capture --data db is not a dump wrap"
if command -v fyrst-cli >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  SHOP="$TMP/acme-staging"
  mkdir -p "$SHOP/deploy"
  cp "$DEPLOY/compose.yaml" "$DEPLOY/compose.prod.yaml" "$DEPLOY/compose.vps.yaml" "$SHOP/deploy/"
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
