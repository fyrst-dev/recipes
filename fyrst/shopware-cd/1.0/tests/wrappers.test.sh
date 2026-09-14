#!/usr/bin/env bash
# Dispatch checks: deploy/*.sh stubs exec fyrst-cli via lib/dispatch.sh.
# No Docker. Does not need a real fyrst-cli binary.
#   bash fyrst/shopware-cd/1.0/tests/wrappers.test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="${ROOT}/root/deploy"
FAILS=0

pass() { printf 'ok  %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MOCK="$TMP/fyrst-cli"
ARGV="$TMP/argv"
LAST_RC=0
cat >"$MOCK" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${FYRST_CLI_ARGV:?}"
EOF
chmod +x "$MOCK"

run_wrap() {
  local script=$1
  shift
  : >"$ARGV"
  set +e
  FYRST_CLI="$MOCK" FYRST_CLI_ARGV="$ARGV" COMPOSE_DIR="$TMP" \
    bash "$DEPLOY/$script" "$@" >/dev/null 2>&1
  LAST_RC=$?
  set -e
}

assert_argv() {
  local want=$1
  local got
  got="$(tr '\n' ' ' <"$ARGV" | sed 's/[[:space:]]*$//')"
  if [[ "$got" == "$want" ]]; then
    pass "argv: $want"
  else
    fail "argv want='$want' got='$got'"
  fi
}

assert_rc() {
  local want=$1
  local label=$2
  if [[ "$LAST_RC" -eq "$want" ]]; then
    pass "rc ${want}: ${label}"
  else
    fail "rc want=${want} got=${LAST_RC}: ${label}"
  fi
}

echo "==> named stubs + helper"
for s in init-env.sh vps-release.sh vps-rollback.sh sync-runtime.sh \
  sync-runtime-local.sh backup-runtime.sh lib/fyrst-cli.sh lib/dispatch.sh
do
  if [[ -f "$DEPLOY/$s" ]]; then
    pass "exists $s"
  else
    fail "missing $s"
  fi
done
for s in init-env.sh vps-release.sh vps-rollback.sh sync-runtime.sh \
  sync-runtime-local.sh backup-runtime.sh
do
  if [[ -x "$DEPLOY/$s" ]]; then
    pass "executable $s"
  else
    fail "not executable $s"
  fi
done

echo "==> stubs are thin dispatch callers"
for s in init-env.sh vps-release.sh vps-rollback.sh sync-runtime.sh \
  sync-runtime-local.sh backup-runtime.sh
do
  stem="${s%.sh}"
  if grep -q 'source "${SCRIPT_DIR}/lib/dispatch.sh"' "$DEPLOY/$s" \
    && grep -q "dispatch ${stem}" "$DEPLOY/$s" \
    && ! grep -q 'fyrst_cli_exec' "$DEPLOY/$s"; then
    pass "stub $s sources dispatch + ${stem}"
  else
    fail "stub $s is not SCRIPT_DIR / source / dispatch ${stem}"
  fi
  lines="$(wc -l <"$DEPLOY/$s")"
  if [[ "$lines" -le 20 ]]; then
    pass "stub $s is ${lines} lines"
  else
    fail "stub $s still too large (${lines} lines)"
  fi
done

echo "==> no leftover implementation libs"
if [[ -e "$DEPLOY/lib/vps-common.sh" || -e "$DEPLOY/lib/sync-dump.sh" || -e "$DEPLOY/lib/sync.sh" ]]; then
  fail "old deploy/lib implementation files still present"
else
  pass "old deploy/lib implementation files removed"
fi
lib_count="$(find "$DEPLOY/lib" -type f -name '*.sh' | wc -l)"
if [[ "$lib_count" -eq 2 ]] \
  && [[ -f "$DEPLOY/lib/fyrst-cli.sh" && -f "$DEPLOY/lib/dispatch.sh" ]]; then
  pass "deploy/lib has fyrst-cli.sh + dispatch.sh"
else
  fail "deploy/lib should have locator + dispatcher, has ${lib_count}"
fi

echo "==> bash -n / shellcheck"
for s in "$DEPLOY"/*.sh "$DEPLOY/lib/fyrst-cli.sh" "$DEPLOY/lib/dispatch.sh"; do
  if bash -n "$s"; then
    pass "bash -n $(basename "$s")"
  else
    fail "bash -n $(basename "$s")"
  fi
done
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "$DEPLOY/init-env.sh" "$DEPLOY/vps-release.sh" \
    "$DEPLOY/vps-rollback.sh" "$DEPLOY/sync-runtime.sh" \
    "$DEPLOY/sync-runtime-local.sh" "$DEPLOY/backup-runtime.sh" \
    "$DEPLOY/lib/fyrst-cli.sh" "$DEPLOY/lib/dispatch.sh"; then
    pass "shellcheck stubs + helper"
  else
    fail "shellcheck wrappers"
  fi
else
  echo "==> shellcheck not installed (bash -n only)"
fi

echo "==> wrappers do not implement compose / dump"
if grep -RIn --include='*.sh' -E '(docker compose --|shopware-cli project dump --)' "$DEPLOY"; then
  fail "wrapper still invokes docker compose or shopware-cli dump"
else
  pass "no docker compose / dump invocations in wrappers"
fi

echo "==> dispatch map (FYRST_CLI mock)"
run_wrap init-env.sh --shop-id acme --vps --dry-run
assert_rc 0 "init-env"
assert_argv "shopware env init --shop-id acme --vps --dry-run"

run_wrap vps-release.sh --skip-pull --dry-run
assert_rc 0 "vps-release"
assert_argv "shopware deploy release --skip-pull --dry-run"

run_wrap vps-rollback.sh --dry-run
assert_rc 0 "vps-rollback"
assert_argv "shopware deploy rollback --dry-run"

run_wrap sync-runtime.sh snapshot --from local --data all --dry-run
assert_rc 0 "sync snapshot"
assert_argv "shopware sync capture --from local --data all --dry-run"

run_wrap sync-runtime.sh restore --snapshot-dir /tmp/s --skip-db
assert_rc 0 "sync restore"
assert_argv "shopware sync apply --snapshot-dir /tmp/s --skip-db"

run_wrap sync-runtime.sh sync --from live --data media,files
assert_rc 0 "sync sync"
assert_argv "shopware sync pull --from live --data media,files"

run_wrap sync-runtime.sh capture --dry-run
assert_rc 0 "sync capture alias"
assert_argv "shopware sync capture --dry-run"

run_wrap sync-runtime-local.sh --from live --data media,files --dry-run
assert_rc 0 "sync-local subset"
assert_argv "shopware sync local --from live --data media,files --dry-run"

run_wrap sync-runtime-local.sh --from live --data all --delete
assert_rc 0 "sync-local drops --data all"
assert_argv "shopware sync local --from live --delete"

run_wrap sync-runtime-local.sh --data=all --dry-run
assert_rc 0 "sync-local drops --data=all"
assert_argv "shopware sync local --dry-run"

run_wrap backup-runtime.sh backup --data all --dry-run
assert_rc 0 "backup backup"
assert_argv "shopware backup create --data all --dry-run"

run_wrap backup-runtime.sh prune --dry-run
assert_rc 0 "backup prune"
assert_argv "shopware backup prune --dry-run"

run_wrap backup-runtime.sh restore --from 20260912T020000Z --i-understand-this-restores-this-host
assert_rc 0 "backup restore"
assert_argv "shopware backup recover --from 20260912T020000Z --i-understand-this-restores-this-host"

run_wrap backup-runtime.sh create --dry-run
assert_rc 0 "backup create alias"
assert_argv "shopware backup create --dry-run"

echo "==> help chains to fyrst-cli --help"
run_wrap init-env.sh --help
assert_rc 0 "init-env --help"
assert_argv "shopware env init --help"

run_wrap sync-runtime.sh --help
assert_rc 0 "sync --help"
assert_argv "shopware sync --help"

run_wrap sync-runtime.sh -h
assert_rc 0 "sync -h"
assert_argv "shopware sync --help"

run_wrap sync-runtime-local.sh --help
assert_rc 0 "sync-local --help"
assert_argv "shopware sync local --help"

run_wrap backup-runtime.sh help
assert_rc 0 "backup help"
assert_argv "shopware backup --help"

run_wrap sync-runtime.sh
assert_rc 2 "sync empty"
if [[ ! -s "$ARGV" ]]; then
  pass "sync empty does not exec fyrst-cli"
else
  fail "sync empty exec'd fyrst-cli: $(cat "$ARGV")"
fi

run_wrap backup-runtime.sh
assert_rc 2 "backup empty"
if [[ ! -s "$ARGV" ]]; then
  pass "backup empty does not exec fyrst-cli"
else
  fail "backup empty exec'd fyrst-cli: $(cat "$ARGV")"
fi

echo "==> missing fyrst-cli"
set +e
out="$(env -u FYRST_CLI PATH="/usr/bin:/bin" COMPOSE_DIR="$TMP" bash "$DEPLOY/vps-release.sh" --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'fyrst-cli is required'; then
  pass "missing fyrst-cli prints install hint"
else
  fail "missing fyrst-cli rc=$rc out=$out"
fi

echo "==> xtrace refuse (sync/backup/init; not vps-release)"
set +e
out="$(FYRST_CLI="$MOCK" FYRST_CLI_ARGV="$ARGV" COMPOSE_DIR="$TMP" \
  bash -x "$DEPLOY/sync-runtime.sh" snapshot --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'refusing to run with xtrace'; then
  pass "sync-runtime refuses bash -x"
else
  fail "sync-runtime xtrace rc=$rc out=$out"
fi
set +e
out="$(FYRST_CLI="$MOCK" FYRST_CLI_ARGV="$ARGV" COMPOSE_DIR="$TMP" \
  bash -x "$DEPLOY/vps-release.sh" --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  pass "vps-release allows bash -x"
else
  fail "vps-release xtrace rc=$rc out=$out"
fi

echo "==> CI still invokes bash ./deploy/vps-release.sh"
if grep -q 'bash ./deploy/vps-release.sh' "$ROOT/root/.github/workflows/cd.yaml" \
  && grep -q 'bash ./deploy/vps-release.sh' "$ROOT/root/.gitlab-ci.yaml"; then
  pass "GitHub + GitLab still run bash ./deploy/vps-release.sh"
else
  fail "CI dropped bash ./deploy/vps-release.sh"
fi
if grep -q 'fyrst-cli 0.1.0' "$ROOT/root/.github/workflows/cd.yaml" \
  && grep -q 'fyrst-cli 0.1.0' "$ROOT/root/.gitlab-ci.yaml"; then
  pass "CI comments require fyrst-cli 0.1.0+ on the VPS"
else
  fail "CI comments missing fyrst-cli requirement"
fi

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nAll wrapper dispatch checks passed.\n'
