#!/usr/bin/env bash
# Overlay contract: wrappers are gone; CI and operators call fyrst-cli only.
#   bash fyrst/shopware-cd/1.0/tests/wrappers.test.sh

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

echo "==> wrappers and dispatcher removed"
for s in init-env.sh vps-release.sh vps-rollback.sh sync-runtime.sh \
  sync-runtime-local.sh backup-runtime.sh lib/fyrst-cli.sh lib/dispatch.sh \
  .shellcheckrc
do
  if [[ -e "$DEPLOY/$s" ]]; then
    fail "still present $s"
  else
    pass "removed $s"
  fi
done
if [[ -d "$DEPLOY/lib" ]]; then
  fail "deploy/lib directory still present"
else
  pass "deploy/lib directory removed"
fi
if compgen -G "$DEPLOY/*.sh" >/dev/null; then
  fail "deploy/*.sh still present: $(echo "$DEPLOY"/*.sh)"
else
  pass "no deploy/*.sh"
fi

echo "==> compose / edge / runtime docs kept"
for s in compose.yaml compose.prod.yaml compose.vps.yaml \
  edge/Caddyfile edge/README.md \
  backup-runtime.md sync-runtime.md
do
  if [[ -f "$DEPLOY/$s" ]]; then
    pass "kept $s"
  else
    fail "missing $s"
  fi
done
echo "==> deploy/*.env.example removed (shop-root .env.example is SoT)"
for s in sync.env.example backup.env.example; do
  if [[ -e "$DEPLOY/$s" ]]; then
    fail "still present $s"
  else
    pass "removed $s"
  fi
done
EXAMPLE="${ROOT}/root/.env.example"
for needle in \
  'SHOPWARE_SSH_HOST=' \
  'SHOPWARE_SSH_USER=' \
  'SHOPWARE_SSH_KEY=' \
  'SHOPWARE_REMOTE_DATA_ROOT=' \
  'BACKUP_TARGET=local' \
  'BACKUP_KEEP_DAYS=14' \
  'BACKUP_DB_DUMP=' \
  'SHOPWARE_ALLOW_LIVE_RESTORE=1'
do
  if grep -q "$needle" "$EXAMPLE"; then
    pass ".env.example comments ${needle}"
  else
    fail ".env.example missing ${needle}"
  fi
done
if grep -qE 'copy deploy/(sync|backup)\.env\.example' "$EXAMPLE" \
  "$DEPLOY/README.md" "$ROOT/root/.github/workflows/cd.yaml" \
  "$ROOT/root/.gitlab-ci.yaml"; then
  fail "docs still say copy deploy/sync.env.example or backup.env.example"
else
  pass "docs do not tell operators to copy deploy/*.env.example"
fi
if [[ -f "$DEPLOY/.gitignore" ]] && grep -qx '\*\.env' "$DEPLOY/.gitignore"; then
  pass "deploy/.gitignore keeps leftover *.env out of git"
else
  fail "deploy/.gitignore missing *.env"
fi

echo "==> CI SSH runs fyrst-cli shopware deploy release"
CD_YAML="$ROOT/root/.github/workflows/cd.yaml"
GL_YAML="$ROOT/root/.gitlab-ci.yaml"
for f in "$CD_YAML" "$GL_YAML"; do
  if grep -q 'bash ./deploy/vps-release.sh' "$f"; then
    fail "$(basename "$f") still requires bash ./deploy/vps-release.sh"
  else
    pass "$(basename "$f") does not invoke bash ./deploy/vps-release.sh"
  fi
  if grep -q 'fyrst-cli shopware deploy release' "$f" \
    && grep -q "IMAGE=" "$f" \
    && grep -q "IMAGE_TAG=" "$f" \
    && grep -q "COMPOSE_DIR=" "$f"; then
    pass "$(basename "$f") SSH step uses fyrst-cli + IMAGE / IMAGE_TAG / COMPOSE_DIR"
  else
    fail "$(basename "$f") missing fyrst-cli deploy release + IMAGE/IMAGE_TAG/COMPOSE_DIR"
  fi
  if grep -q 'fyrst-cli 0.1.0' "$f"; then
    pass "$(basename "$f") comments require fyrst-cli 0.1.0+"
  else
    fail "$(basename "$f") comments missing fyrst-cli requirement"
  fi
done

echo "==> overlay verb aliases retired (lifecycle verbs only)"
set +e
out="$(fyrst-cli shopware sync snapshot --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -qiE 'unrecognized subcommand|unexpected argument|invalid'; then
  pass "sync snapshot is not a CLI verb"
else
  fail "sync snapshot still accepted rc=$rc out=$out"
fi
set +e
out="$(fyrst-cli shopware backup backup --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -qiE 'unrecognized subcommand|unexpected argument|invalid'; then
  pass "backup backup is not a CLI verb"
else
  fail "backup backup still accepted rc=$rc out=$out"
fi

echo "==> fyrst-cli lifecycle help"
for cmd in \
  "shopware env init --help" \
  "shopware deploy release --help" \
  "shopware deploy rollback --help" \
  "shopware sync capture --help" \
  "shopware sync apply --help" \
  "shopware sync pull --help" \
  "shopware sync local --help" \
  "shopware backup create --help" \
  "shopware backup prune --help" \
  "shopware backup recover --help"
do
  set +e
  out="$(fyrst-cli $cmd 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    pass "fyrst-cli $cmd"
  else
    fail "fyrst-cli $cmd rc=$rc out=$out"
  fi
done

echo "==> sync local --data all stays rejected"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SHOP="$TMP/laptop"
mkdir -p "$SHOP/deploy"
cp "$DEPLOY/compose.yaml" "$DEPLOY/compose.prod.yaml" "$DEPLOY/compose.vps.yaml" "$SHOP/deploy/"
cat >"$SHOP/.env" <<'EOF'
IMAGE=ghcr.io/example/acme
IMAGE_TAG=tag-b
SHOPWARE_SHOP_ID=acme
SHOPWARE_DEPLOY_ENV=dev
EOF
set +e
out="$(cd "$SHOP" && fyrst-cli shopware sync local --from live --data all --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'Refusing --data all'; then
  pass "sync local --data all refused"
else
  fail "sync local --data all rc=$rc out=$out"
fi
set +e
out="$(cd "$SHOP" && fyrst-cli shopware sync local --from live --data=all --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'Refusing --data all'; then
  pass "sync local --data=all refused"
else
  fail "sync local --data=all rc=$rc out=$out"
fi

echo "==> cron/docs use lifecycle verbs"
if grep -q 'fyrst-cli shopware sync pull --from live --data all' "$DEPLOY/README.md" \
  && grep -q 'fyrst-cli shopware backup create' "$DEPLOY/README.md" \
  && ! grep -q 'bash ./deploy/vps-release.sh' "$DEPLOY/README.md" \
  && ! grep -q 'bash deploy/sync-runtime.sh' "$DEPLOY/README.md"; then
  pass "deploy README cron/CI examples are fyrst-cli lifecycle verbs"
else
  fail "deploy README still documents bash wrappers as the operator path"
fi
if grep -q 'fyrst-cli shopware sync local' "$DEPLOY/README.md" \
  && grep -q 'refused' "$DEPLOY/README.md"; then
  pass "deploy README documents sync local --data all refuse"
else
  fail "deploy README missing sync local refuse"
fi

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nAll overlay fyrst-cli checks passed.\n'
