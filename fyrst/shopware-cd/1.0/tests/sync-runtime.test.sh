#!/usr/bin/env bash
# Wrapper + docs checks for deploy/sync-runtime.sh (fyrst-cli dispatch).
#   bash fyrst/shopware-cd/1.0/tests/sync-runtime.test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="${ROOT}/root/deploy"
FAILS=0

pass() { printf 'ok  %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

echo "==> bash -n / shellcheck entrypoint + helper"
for s in "$DEPLOY/lib/fyrst-cli.sh" "$DEPLOY/lib/dispatch.sh" "$DEPLOY/sync-runtime.sh"; do
  if bash -n "$s"; then
    pass "bash -n $(basename "$s")"
  else
    fail "bash -n $(basename "$s")"
  fi
done
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "$DEPLOY/sync-runtime.sh" "$DEPLOY/lib/dispatch.sh" "$DEPLOY/lib/fyrst-cli.sh"; then
    pass "shellcheck sync-runtime + helper"
  else
    fail "shellcheck sync-runtime + helper"
  fi
else
  echo "==> shellcheck not installed (bash -n only)"
fi

echo "==> entrypoint is a thin dispatch stub"
if grep -q 'source "${SCRIPT_DIR}/lib/dispatch.sh"' "$DEPLOY/sync-runtime.sh" \
  && grep -q 'dispatch sync-runtime' "$DEPLOY/sync-runtime.sh" \
  && ! grep -q 'fyrst_cli_exec' "$DEPLOY/sync-runtime.sh" \
  && ! grep -q '^do_snapshot()' "$DEPLOY/sync-runtime.sh" \
  && ! grep -q '^dump_db_local()' "$DEPLOY/sync-runtime.sh"; then
  pass "sync-runtime.sh is a dispatch stub"
else
  fail "sync-runtime.sh is not a dispatch stub"
fi
lines="$(wc -l <"$DEPLOY/sync-runtime.sh")"
if [[ "$lines" -le 20 ]]; then
  pass "entrypoint is ${lines} lines"
else
  fail "entrypoint still too large (${lines} lines)"
fi

echo "==> dispatch argv via FYRST_CLI mock"
TMP_MOCK="$(mktemp -d)"
MOCK="$TMP_MOCK/fyrst-cli"
ARGV="$TMP_MOCK/argv"
cat >"$MOCK" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${FYRST_CLI_ARGV:?}"
EOF
chmod +x "$MOCK"
run_sync() {
  : >"$ARGV"
  FYRST_CLI="$MOCK" FYRST_CLI_ARGV="$ARGV" COMPOSE_DIR="$TMP_MOCK" \
    bash "$DEPLOY/sync-runtime.sh" "$@" >/dev/null 2>&1
}
want_argv() {
  local want=$1
  local got
  got="$(tr '\n' ' ' <"$ARGV" | sed 's/[[:space:]]*$//')"
  if [[ "$got" == "$want" ]]; then
    pass "argv: $want"
  else
    fail "argv want='$want' got='$got'"
  fi
}
run_sync snapshot --from local --data all --dry-run
want_argv "shopware sync capture --from local --data all --dry-run"
run_sync restore --snapshot-dir /tmp/s --skip-db
want_argv "shopware sync apply --snapshot-dir /tmp/s --skip-db"
run_sync sync --from live --data media,files
want_argv "shopware sync pull --from live --data media,files"
run_sync --help
want_argv "shopware sync --help"
rm -rf "$TMP_MOCK"

echo "==> docs keep cron + dump ownership"
if grep -q 'bash deploy/sync-runtime.sh sync --from live --data all' "$DEPLOY/sync-runtime.md" \
  && grep -q 'shopware-cli project dump' "$DEPLOY/sync-runtime.md" \
  && grep -q 'fyrst-cli never dumps' "$DEPLOY/sync-runtime.md"; then
  pass "sync-runtime.md documents wrapper cron + shopware-cli dump"
else
  fail "sync-runtime.md missing wrapper/dump contract"
fi
if grep -q 'fyrst-cli shopware sync' "$DEPLOY/sync-runtime.md"; then
  pass "sync-runtime.md names fyrst-cli verbs"
else
  fail "sync-runtime.md missing fyrst-cli verb map"
fi

if command -v fyrst-cli >/dev/null 2>&1; then
  echo "==> live refuse via wrapper (real fyrst-cli)"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  SHOP="$TMP/acme-live"
  mkdir -p "$SHOP/deploy/lib" "$SHOP/var/runtime-sync"
  cp "$DEPLOY/sync-runtime.sh" "$SHOP/deploy/"
  cp "$DEPLOY/lib/"*.sh "$SHOP/deploy/lib/"
  cp "$DEPLOY/compose.yaml" "$DEPLOY/compose.prod.yaml" "$DEPLOY/compose.vps.yaml" "$SHOP/deploy/"
  chmod +x "$SHOP/deploy/sync-runtime.sh"
  cat >"$SHOP/.env" <<'EOF'
IMAGE=ghcr.io/example/acme
IMAGE_TAG=tag-b
SHOPWARE_SHOP_ID=acme
SHOPWARE_DEPLOY_ENV=live
EOF
  set +e
  out="$(cd "$SHOP" && bash deploy/sync-runtime.sh restore --dry-run --snapshot-dir "$SHOP/var/runtime-sync" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'Refusing restore/sync on a live host'; then
    pass "wrapper restore refuses live"
  else
    fail "wrapper live restore rc=$rc out=$out"
  fi
else
  echo "==> skipping live-refuse (fyrst-cli not installed)"
fi

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nAll sync-runtime wrapper checks passed.\n'
