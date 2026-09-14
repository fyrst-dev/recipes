#!/usr/bin/env bash
# Dispatch checks: deploy/*.sh exec fyrst-cli with the mapped verbs.
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

echo "==> named wrappers + helper"
for s in init-env.sh vps-release.sh vps-rollback.sh sync-runtime.sh \
  sync-runtime-local.sh backup-runtime.sh lib/fyrst-cli.sh
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

echo "==> no leftover implementation libs"
if [[ -e "$DEPLOY/lib/vps-common.sh" || -e "$DEPLOY/lib/sync-dump.sh" || -e "$DEPLOY/lib/sync.sh" ]]; then
  fail "old deploy/lib implementation files still present"
else
  pass "old deploy/lib implementation files removed"
fi
lib_count="$(find "$DEPLOY/lib" -type f -name '*.sh' | wc -l)"
if [[ "$lib_count" -eq 1 ]]; then
  pass "deploy/lib has only fyrst-cli.sh"
else
  fail "deploy/lib should have one helper, has ${lib_count}"
fi

echo "==> bash -n / shellcheck"
for s in "$DEPLOY"/*.sh "$DEPLOY/lib/fyrst-cli.sh"; do
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
    "$DEPLOY/lib/fyrst-cli.sh"; then
    pass "shellcheck wrappers + helper"
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

echo "==> dispatch map"
run_wrap init-env.sh --shop-id acme --vps --dry-run
assert_argv "shopware env init --shop-id acme --vps --dry-run"

run_wrap vps-release.sh --skip-pull --dry-run
assert_argv "shopware deploy release --skip-pull --dry-run"

run_wrap vps-rollback.sh --dry-run
assert_argv "shopware deploy rollback --dry-run"

run_wrap sync-runtime.sh snapshot --from local --data all --dry-run
assert_argv "shopware sync capture --from local --data all --dry-run"

run_wrap sync-runtime.sh restore --snapshot-dir /tmp/s --skip-db
assert_argv "shopware sync apply --snapshot-dir /tmp/s --skip-db"

run_wrap sync-runtime.sh sync --from live --data media,files
assert_argv "shopware sync pull --from live --data media,files"

run_wrap sync-runtime.sh capture --dry-run
assert_argv "shopware sync capture --dry-run"

run_wrap sync-runtime-local.sh --from live --data media,files --dry-run
assert_argv "shopware sync local --from live --data media,files --dry-run"

run_wrap sync-runtime-local.sh --from live --data all --delete
assert_argv "shopware sync local --from live --delete"

run_wrap sync-runtime-local.sh --data=all --dry-run
assert_argv "shopware sync local --dry-run"

run_wrap backup-runtime.sh backup --data all --dry-run
assert_argv "shopware backup create --data all --dry-run"

run_wrap backup-runtime.sh prune --dry-run
assert_argv "shopware backup prune --dry-run"

run_wrap backup-runtime.sh restore --from 20260912T020000Z --i-understand-this-restores-this-host
assert_argv "shopware backup recover --from 20260912T020000Z --i-understand-this-restores-this-host"

run_wrap backup-runtime.sh create --dry-run
assert_argv "shopware backup create --dry-run"

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
