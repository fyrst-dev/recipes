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
  && printf '%s' "$out" | grep -q -- '--dry-run' \
  && printf '%s' "$out" | grep -q 'APP_SECRET' \
  && printf '%s' "$out" | grep -q 'COMPOSE_PROJECT_NAME' \
  && ! printf '%s' "$out" | grep -q -- '--vps' \
  && ! printf '%s' "$out" | grep -q 'generate-app-secret'; then
  pass "--help lists identity flags; documents COMPOSE_PROJECT_NAME; no --vps"
else
  fail "--help rc=$rc out=$out"
fi

echo "==> recipe docs omit --vps / --generate-app-secret; env init sets COMPOSE_PROJECT_NAME"
REPO_README="$(cd "$ROOT/../../.." && pwd)/README.md"
if ! grep -q 'generate-app-secret' "$ROOT/post-install.txt" \
  && ! grep -q 'generate-app-secret' "$ROOT/README.md" \
  && ! grep -q -- '--vps' "$ROOT/post-install.txt" \
  && ! grep -q -- '--vps' "$ROOT/README.md" \
  && ! grep -q -- '--vps' "$REPO_README" \
  && ! grep -q 'always comments out' "$ROOT/post-install.txt" \
  && ! grep -q 'always comments out' "$ROOT/README.md" \
  && ! grep -q 'always comments out' "$REPO_README" \
  && grep -q 'APP_SECRET' "$ROOT/post-install.txt" \
  && grep -q 'APP_SECRET' "$ROOT/README.md" \
  && grep -q 'COMPOSE_PROJECT_NAME=shopware-' "$ROOT/post-install.txt" \
  && grep -q 'COMPOSE_PROJECT_NAME=shopware-' "$ROOT/README.md" \
  && grep -q 'COMPOSE_PROJECT_NAME=shopware-' "$REPO_README" \
  && grep -q 'shopware-acme' "$ROOT/post-install.txt" \
  && grep -q 'shopware-acme' "$ROOT/README.md" \
  && grep -q 'shopware-acme' "$REPO_README" \
  && grep -q -- '--env-file .env' "$ROOT/post-install.txt" \
  && grep -q -- '--env-file .env' "$ROOT/README.md" \
  && grep -q -- '--env-file .env' "$REPO_README" \
  && grep -q 'Docker Compose precedence' "$ROOT/post-install.txt" \
  && grep -q 'Docker Compose precedence' "$ROOT/README.md" \
  && grep -q 'Docker Compose precedence' "$REPO_README" \
  && grep -q 'laptop and VPS same' "$ROOT/post-install.txt" \
  && grep -q 'laptop and VPS same' "$ROOT/README.md" \
  && grep -q 'laptop and VPS same' "$REPO_README"; then
  pass "recipe docs: env init sets COMPOSE_PROJECT_NAME=shopware-<shop-id>; laptop and VPS same"
else
  fail "recipe docs still mention --vps / --generate-app-secret / always-strip or miss shopware-<shop-id>"
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

echo "==> dry-run does not write; real run sets COMPOSE_PROJECT_NAME=shopware-<shop-id>"
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
out="$(COMPOSE_DIR="$SHOP" fyrst-cli shopware env init --shop-id acme --env live --image ghcr.io/example/acme --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'DRY-RUN' \
  && printf '%s' "$out" | grep -q 'SHOPWARE_SHOP_ID=acme' \
  && printf '%s' "$out" | grep -q 'COMPOSE_PROJECT_NAME' \
  && printf '%s' "$out" | grep -q 'shopware-acme' \
  && printf '%s' "$out" | grep -q 'IMAGE=ghcr.io/example/acme' \
  && printf '%s' "$out" | grep -q 'APP_SECRET' \
  && ! printf '%s' "$out" | grep -q -- '--vps' \
  && ! printf '%s' "$out" | grep -q 'generate-app-secret' \
  && ! printf '%s' "$out" | grep -q 'set APP_SECRET' \
  && ! printf '%s' "$out" | grep -q 'oldsecret' \
  && ! printf '%s' "$out" | grep -qE 'commented [0-9]|always comments'; then
  pass "dry-run summary sets shop id, image, and COMPOSE_PROJECT_NAME=shopware-acme without --vps"
else
  fail "dry-run rc=$rc out=$out"
fi
if cmp -s "$SHOP/.env" "$SHOP/.env.before"; then
  pass "dry-run does not write .env"
else
  fail "dry-run mutated .env"
fi

set +e
out="$(COMPOSE_DIR="$SHOP" fyrst-cli shopware env init --shop-id acme --env live --image ghcr.io/example/acme 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'SHOPWARE_SHOP_ID=acme' \
  && printf '%s' "$out" | grep -q 'COMPOSE_PROJECT_NAME' \
  && printf '%s' "$out" | grep -q 'shopware-acme' \
  && ! printf '%s' "$out" | grep -qE 'commented [0-9]|always comments' \
  && ! printf '%s' "$out" | grep -q -- '--vps'; then
  pass "real run summary sets shop id and COMPOSE_PROJECT_NAME=shopware-acme"
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
cpn_count="$(grep -c '^COMPOSE_PROJECT_NAME=' "$envf" || true)"
if grep -q '^COMPOSE_PROJECT_NAME=shopware-acme$' "$envf" \
  && [[ "$cpn_count" -eq 1 ]] \
  && ! grep -q 'sw-shop-acme' "$envf" \
  && ! grep -q -- '--vps' "$envf" \
  && ! grep -qE '^COMPOSE_PROJECT_NAME=(acme-live|shopware-acme-live)$' "$envf" \
  && ! grep -q '^COMPOSE_PROJECT_NAME=$' "$envf"; then
  pass "sets COMPOSE_PROJECT_NAME=shopware-acme (replaces create’s sw-shop-…; no env suffix)"
else
  fail "did not set COMPOSE_PROJECT_NAME=shopware-acme: $(grep COMPOSE_PROJECT_NAME "$envf" || true)"
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
  && grep -q '^SHOPWARE_DEPLOY_ENV=staging$' "$COPY_SHOP/.env" \
  && grep -q '^COMPOSE_PROJECT_NAME=shopware-widgets$' "$COPY_SHOP/.env" \
  && ! grep -qE '^COMPOSE_PROJECT_NAME=(widgets-staging|shopware-widgets-staging)$' "$COPY_SHOP/.env"; then
  pass "creates .env from .env.example and sets --shop-id / --env / COMPOSE_PROJECT_NAME=shopware-widgets"
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

echo "==> existing shop id without --shop-id; APP_SECRET left alone"
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
  && grep -q '^SHOPWARE_DEPLOY_ENV=staging$' "$KEEP/.env" \
  && grep -q '^COMPOSE_PROJECT_NAME=shopware-acme$' "$KEEP/.env"; then
  pass "keeps existing shop id and deploy env; sets COMPOSE_PROJECT_NAME=shopware-acme"
else
  fail "keep existing rc=$rc out=$out"
fi
if grep -q '^APP_URL=$' "$KEEP/.env"; then
  pass "does not invent APP_URL"
else
  fail "invented APP_URL"
fi
secret="$(grep '^APP_SECRET=' "$KEEP/.env" | tail -n1 | cut -d= -f2-)"
if [[ "$secret" == "" ]] && ! printf '%s' "$out" | grep -q 'generate-app-secret' \
  && ! printf '%s' "$out" | grep -q 'set APP_SECRET'; then
  pass "does not generate empty APP_SECRET"
else
  fail "empty APP_SECRET rewritten secret=${secret:-missing} out=$out"
fi
set +e
out="$(COMPOSE_DIR="$KEEP" fyrst-cli shopware env init --generate-app-secret 2>&1)"
rc=$?
set -e
secret2="$(grep '^APP_SECRET=' "$KEEP/.env" | tail -n1 | cut -d= -f2-)"
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -qiE 'unexpected argument|unexpected' \
  && [[ "$secret2" == "" ]]; then
  pass "--generate-app-secret is rejected; APP_SECRET still empty"
else
  fail "generate-app-secret still accepted rc=$rc secret2=$secret2 out=$out"
fi

echo "==> laptop env init also sets COMPOSE_PROJECT_NAME=shopware-<shop-id>"
LAP="$TMP/laptop"
mkdir -p "$LAP"
write_stub_env_example "$LAP"
cat >"$LAP/.env" <<'EOF'
SHOPWARE_SHOP_ID=
SHOPWARE_DEPLOY_ENV=dev
COMPOSE_PROJECT_NAME=sw-shop-widgets
EOF
set +e
out="$(COMPOSE_DIR="$LAP" fyrst-cli shopware env init --shop-id widgets 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q '^COMPOSE_PROJECT_NAME=shopware-widgets$' "$LAP/.env" \
  && grep -q '^SHOPWARE_DEPLOY_ENV=dev$' "$LAP/.env" \
  && ! grep -q 'sw-shop-widgets' "$LAP/.env" \
  && ! grep -qE '^COMPOSE_PROJECT_NAME=(widgets-dev|shopware-widgets-dev)$' "$LAP/.env" \
  && printf '%s' "$out" | grep -q 'shopware-widgets' \
  && ! printf '%s' "$out" | grep -qE 'commented [0-9]|always comments' \
  && ! printf '%s' "$out" | grep -q -- '--vps'; then
  pass "laptop env init sets COMPOSE_PROJECT_NAME=shopware-widgets (same as VPS; no env suffix)"
else
  fail "laptop COMPOSE_PROJECT_NAME rc=$rc out=$out env=$(grep COMPOSE_PROJECT_NAME "$LAP/.env" || true)"
fi

echo "==> --vps is rejected"
set +e
out="$(COMPOSE_DIR="$SHOP" fyrst-cli shopware env init --shop-id acme --vps 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -qiE 'unexpected argument|unexpected'; then
  pass "--vps is rejected"
else
  fail "--vps still accepted rc=$rc out=$out"
fi

echo "==> COMPOSE_PROJECT_NAME=shopware-<shop-id> is idempotent"
set +e
out="$(COMPOSE_DIR="$SHOP" fyrst-cli shopware env init --shop-id acme 2>&1)"
rc=$?
set -e
count="$(grep -c '^COMPOSE_PROJECT_NAME=shopware-acme$' "$SHOP/.env" || true)"
if [[ "$rc" -eq 0 && "$count" -eq 1 ]] \
  && ! grep -q 'sw-shop-acme' "$SHOP/.env" \
  && ! printf '%s' "$out" | grep -q -- '--vps'; then
  pass "second env init keeps a single COMPOSE_PROJECT_NAME=shopware-acme"
else
  fail "idempotent COMPOSE_PROJECT_NAME rc=$rc count=$count out=$out"
fi

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nAll init-env checks passed.\n'
