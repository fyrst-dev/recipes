#!/usr/bin/env bash
# Acceptance checks for fyrst-cli shopware env init (post-create .env automation).
# No Docker required. Run from anywhere:
#   bash fyrst/shopware-cd/1.0/tests/init-env.test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=fixtures.sh
source "$(dirname "$0")/fixtures.sh"
FAILS=0

require_fyrst_cli

pass() { printf 'ok  %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

echo "==> --help"
set +e
out="$(fyrst-cli shopware env init --help 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q -- '--shop-id' \
  && printf '%s' "$out" | grep -q -- '--vps' \
  && printf '%s' "$out" | grep -q -- '--dry-run'; then
  pass "--help lists --shop-id / --vps / --dry-run"
else
  fail "--help rc=$rc out=$out"
fi

echo "==> manifest Flex env (safe defaults) + copy-from-package"
MANIFEST="${ROOT}/manifest.json"
if python3 - "$MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
env = m.get("env") or {}
ok = (
    m.get("copy-from-package") == {"overlay/": ""}
    and "copy-from-recipe" not in m
    and env.get("SHOPWARE_SHOP_ID") == ""
    and env.get("SHOPWARE_DEPLOY_ENV") == "live"
    and env.get("SHOPWARE_DATA_BASE") == "/var/lib/shopware/data"
)
raise SystemExit(0 if ok else 1)
PY
then
  pass "manifest.json is copy-from-package + locked env defaults"
else
  fail "manifest.json env/copy block is not the locked thin recipe"
fi

echo "==> refuses missing .env and .env.example"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
EMPTY="$TMP/empty"
mkdir -p "$EMPTY"
set +e
out="$(COMPOSE_DIR="$EMPTY" fyrst-cli shopware env init --shop-id acme 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'Missing' \
  && printf '%s' "$out" | grep -q '\.env' \
  && printf '%s' "$out" | grep -q '\.env.example'; then
  pass "refuses when both .env and .env.example are missing"
else
  fail "missing both files rc=$rc out=$out"
fi

echo "==> dry-run does not write; real run merges + sets shop id + --vps"
SHOP="$TMP/acme"
mkdir -p "$SHOP"
write_stub_env_example "$SHOP"
cat >"$SHOP/.env" <<'EOF'
APP_ENV=prod
APP_URL=https://keep.example
APP_SECRET=oldsecret
MYSQL_PASSWORD=keepme
MYSQL_ROOT_PASSWORD=keep-root
COMPOSE_PROJECT_NAME=sw-shop-acme

###> fyrst/shopware-cd ###
SHOPWARE_SHOP_ID=
SHOPWARE_DEPLOY_ENV=live
SHOPWARE_DATA_BASE=/var/lib/shopware/data
###< fyrst/shopware-cd ###
EOF
cp "$SHOP/.env" "$SHOP/.env.before"

set +e
out="$(COMPOSE_DIR="$SHOP" fyrst-cli shopware env init --shop-id acme --env live --vps --image ghcr.io/example/acme --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'DRY-RUN' \
  && printf '%s' "$out" | grep -q 'SHOPWARE_SHOP_ID=acme' \
  && printf '%s' "$out" | grep -q 'COMPOSE_PROJECT_NAME' \
  && printf '%s' "$out" | grep -q 'IMAGE=ghcr.io/example/acme'; then
  pass "dry-run summary sets shop id, image, and mentions COMPOSE_PROJECT_NAME"
else
  fail "dry-run rc=$rc out=$out"
fi
if cmp -s "$SHOP/.env" "$SHOP/.env.before"; then
  pass "dry-run does not write .env"
else
  fail "dry-run mutated .env"
fi

set +e
out="$(COMPOSE_DIR="$SHOP" fyrst-cli shopware env init --shop-id acme --env live --vps --image ghcr.io/example/acme 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'SHOPWARE_SHOP_ID=acme' \
  && printf '%s' "$out" | grep -q 'commented' \
  && printf '%s' "$out" | grep -q 'COMPOSE_PROJECT_NAME'; then
  pass "real run summary sets shop id and comments COMPOSE_PROJECT_NAME"
else
  fail "real run rc=$rc out=$out"
fi

envf="$SHOP/.env"
if grep -q '^SHOPWARE_SHOP_ID=acme$' "$envf" \
  && grep -q '^SHOPWARE_DEPLOY_ENV=live$' "$envf" \
  && grep -q '^IMAGE=ghcr.io/example/acme$' "$envf"; then
  pass "real run writes shop id, deploy env, and IMAGE"
else
  fail "real run did not write SoT keys: $(grep -E '^(SHOPWARE_|IMAGE=)' "$envf" || true)"
fi
if grep -q '^APP_URL=https://keep.example$' "$envf" \
  && grep -q '^MYSQL_PASSWORD=keepme$' "$envf" \
  && grep -q '^APP_SECRET=oldsecret$' "$envf"; then
  pass "does not clobber existing APP_URL / MYSQL_PASSWORD / APP_SECRET"
else
  fail "clobbered operator secrets"
fi
if grep -q '^# COMPOSE_PROJECT_NAME=sw-shop-acme' "$envf" \
  && grep -q 'restore for local project dev' "$envf" \
  && ! grep -q '^COMPOSE_PROJECT_NAME=' "$envf" \
  && ! grep -q '^COMPOSE_PROJECT_NAME=$' "$envf"; then
  pass "--vps comments COMPOSE_PROJECT_NAME and does not leave COMPOSE_PROJECT_NAME="
else
  fail "--vps did not comment COMPOSE_PROJECT_NAME correctly: $(grep COMPOSE_PROJECT_NAME "$envf" || true)"
fi
if grep -q '^HTTP_PORT=' "$envf" && grep -q '^MYSQL_DATABASE=' "$envf"; then
  pass "merged missing keys from .env.example"
else
  fail "did not merge missing keys from .env.example"
fi
if grep -q '^###> fyrst/shopware-cd ###$' "$envf" \
  && grep -A3 '^###> fyrst/shopware-cd ###$' "$envf" | grep -q '^SHOPWARE_SHOP_ID=acme$'; then
  pass "updates shop id inside the Flex marker block"
else
  fail "Flex marker block shop id not updated"
fi

echo "==> copy .env.example when .env is missing"
COPY_SHOP="$TMP/copy-shop"
mkdir -p "$COPY_SHOP"
write_stub_env_example "$COPY_SHOP"
set +e
out="$(COMPOSE_DIR="$COPY_SHOP" fyrst-cli shopware env init --shop-id widgets --env staging 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 && -f "$COPY_SHOP/.env" ]] && printf '%s' "$out" | grep -q 'copy .env.example' \
  && grep -q '^SHOPWARE_SHOP_ID=widgets$' "$COPY_SHOP/.env" \
  && grep -q '^SHOPWARE_DEPLOY_ENV=staging$' "$COPY_SHOP/.env"; then
  pass "creates .env from .env.example and sets --shop-id / --env"
else
  fail "copy-from-example rc=$rc out=$out"
fi
if [[ -f "$COPY_SHOP/.env" ]]; then
  mode="$(stat -c '%a' "$COPY_SHOP/.env")"
  if [[ "$mode" == "600" ]]; then
    pass "chmod 600 .env after write"
  else
    fail ".env mode is ${mode}, expected 600"
  fi
fi

echo "==> --shop-id required when empty; invalid --env refused"
NEED="$TMP/need-id"
mkdir -p "$NEED"
printf 'APP_URL=\nSHOPWARE_SHOP_ID=\n' >"$NEED/.env"
write_stub_env_example "$NEED"
set +e
out="$(COMPOSE_DIR="$NEED" fyrst-cli shopware env init 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q -- '--shop-id'; then
  pass "refuses empty SHOPWARE_SHOP_ID without --shop-id"
else
  fail "empty shop id rc=$rc out=$out"
fi
set +e
out="$(COMPOSE_DIR="$SHOP" fyrst-cli shopware env init --shop-id acme --env prod 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -qiE 'invalid value|live, staging, playground'; then
  pass "refuses invalid --env"
else
  fail "invalid --env rc=$rc out=$out"
fi

echo "==> existing shop id without --shop-id; --generate-app-secret"
KEEP="$TMP/keep-id"
mkdir -p "$KEEP"
cat >"$KEEP/.env" <<'EOF'
SHOPWARE_SHOP_ID=acme
SHOPWARE_DEPLOY_ENV=staging
APP_SECRET=
APP_URL=
EOF
write_stub_env_example "$KEEP"
set +e
out="$(COMPOSE_DIR="$KEEP" fyrst-cli shopware env init 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q '^SHOPWARE_SHOP_ID=acme$' "$KEEP/.env" \
  && grep -q '^SHOPWARE_DEPLOY_ENV=staging$' "$KEEP/.env"; then
  pass "keeps existing shop id and deploy env without flags"
else
  fail "keep existing rc=$rc out=$out"
fi
if grep -q '^APP_URL=$' "$KEEP/.env"; then
  pass "does not invent APP_URL"
else
  fail "invented APP_URL"
fi
set +e
out="$(COMPOSE_DIR="$KEEP" fyrst-cli shopware env init --generate-app-secret 2>&1)"
rc=$?
set -e
secret="$(grep '^APP_SECRET=' "$KEEP/.env" | tail -n1 | cut -d= -f2-)"
if [[ "$rc" -eq 0 && "$secret" =~ ^[0-9a-f]{64}$ ]] && printf '%s' "$out" | grep -q 'APP_SECRET' \
  && ! printf '%s' "$out" | grep -q "$secret"; then
  pass "--generate-app-secret fills empty APP_SECRET (64 hex; value not printed)"
else
  fail "generate-app-secret rc=$rc secret_len=${#secret} out=$out"
fi
old_secret=$secret
set +e
out="$(COMPOSE_DIR="$KEEP" fyrst-cli shopware env init --generate-app-secret 2>&1)"
rc=$?
set -e
secret2="$(grep '^APP_SECRET=' "$KEEP/.env" | tail -n1 | cut -d= -f2-)"
if [[ "$rc" -eq 0 && "$secret2" == "$old_secret" ]] && printf '%s' "$out" | grep -q 'already set'; then
  pass "--generate-app-secret is idempotent when APP_SECRET is set"
else
  fail "generate-app-secret clobbered rc=$rc out=$out"
fi

echo "==> --vps is idempotent (already commented)"
set +e
out="$(COMPOSE_DIR="$SHOP" fyrst-cli shopware env init --shop-id acme --vps 2>&1)"
rc=$?
set -e
count="$(grep -c 'commented by deploy/init-env.sh --vps' "$SHOP/.env" || true)"
if [[ "$rc" -eq 0 && "$count" -eq 1 ]] && printf '%s' "$out" | grep -q 'no uncommented COMPOSE_PROJECT_NAME'; then
  pass "second --vps does not double-comment"
else
  fail "idempotent --vps rc=$rc count=$count out=$out"
fi

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nAll init-env checks passed.\n'
