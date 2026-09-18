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

# Shared committed .env must not carry an env-specific deploy env.
no_deploy_env_in_dotenv() {
  ! grep -qE '^SHOPWARE_DEPLOY_ENV=.+$' "$1"
}

override_has_name() {
  local shop="$1" proj="$2"
  [[ -f "$shop/compose.override.yaml" ]] \
    && grep -qE "^name:[[:space:]]*['\"]?${proj}['\"]?[[:space:]]*$" "$shop/compose.override.yaml"
}

# Host .env.local holds deploy env + COMPOSE_PROJECT_NAME=<shop-id>-<env>;
# compose.override.yaml name: matches so project dev sees it.
local_project_identity() {
  local shop="$1" denv="$2" proj="$3"
  [[ -f "$shop/.env.local" ]] \
    && grep -q "^SHOPWARE_DEPLOY_ENV=${denv}$" "$shop/.env.local" \
    && grep -q "^COMPOSE_PROJECT_NAME=${proj}$" "$shop/.env.local" \
    && override_has_name "$shop" "$proj"
}

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

echo "==> recipe docs: .env.local owns deploy env + COMPOSE_PROJECT_NAME=<shop-id>-<env>"
REPO_README="$(cd "$ROOT/../../.." && pwd)/README.md"
if ! grep -q 'generate-app-secret' "$ROOT/post-install.txt" \
  && ! grep -q 'generate-app-secret' "$ROOT/README.md" \
  && ! grep -q -- '--vps' "$ROOT/post-install.txt" \
  && ! grep -q -- '--vps' "$ROOT/README.md" \
  && ! grep -q -- '--vps' "$REPO_README" \
  && grep -q 'always comments out' "$ROOT/post-install.txt" \
  && grep -q 'always comments out' "$ROOT/README.md" \
  && grep -q 'always comments out' "$REPO_README" \
  && grep -q 'APP_SECRET' "$ROOT/post-install.txt" \
  && grep -q 'APP_SECRET' "$ROOT/README.md" \
  && grep -q '.env.local' "$ROOT/post-install.txt" \
  && grep -q '.env.local' "$ROOT/README.md" \
  && grep -q '.env.local' "$REPO_README" \
  && grep -q 'host `.env.local` owns' "$ROOT/README.md" \
  && grep -q 'host `.env.local` owns' "$REPO_README" \
  && grep -q 'host <comment>.env.local</comment> owns' "$ROOT/post-install.txt" \
  && grep -q 'does not write' "$ROOT/post-install.txt" \
  && grep -q 'does not write' "$ROOT/README.md" \
  && grep -q 'does not write' "$REPO_README" \
  && grep -q 'acme-live' "$ROOT/post-install.txt" \
  && grep -q 'acme-live' "$ROOT/README.md" \
  && grep -q 'acme-live' "$REPO_README" \
  && grep -q 'acme-dev' "$ROOT/post-install.txt" \
  && grep -q 'acme-dev' "$ROOT/README.md" \
  && grep -q 'acme-dev' "$REPO_README" \
  && grep -q 'compose.override.yaml' "$ROOT/post-install.txt" \
  && grep -q 'compose.override.yaml' "$ROOT/README.md" \
  && grep -q 'compose.override.yaml' "$REPO_README" \
  && grep -q 'folder basename' "$ROOT/post-install.txt" \
  && grep -q 'folder basename' "$ROOT/README.md" \
  && grep -q 'folder basename' "$REPO_README" \
  && grep -q -- '--env-file .env.local' "$ROOT/post-install.txt" \
  && grep -q -- '--env-file .env.local' "$ROOT/README.md" \
  && grep -q -- '--env-file .env.local' "$REPO_README" \
  && grep -q -- '--env-file .env.prod' "$ROOT/post-install.txt" \
  && grep -q -- '--env-file .env.prod' "$ROOT/README.md" \
  && grep -q -- '--env-file .env.prod' "$REPO_README" \
  && ! grep -q 'matching pin' "$ROOT/post-install.txt" \
  && ! grep -q 'matching pin' "$ROOT/README.md" \
  && ! grep -q 'matching pin' "$REPO_README" \
  && ! grep -q 'may pin' "$ROOT/post-install.txt" \
  && ! grep -q 'may pin' "$ROOT/README.md" \
  && ! grep -q 'may pin' "$REPO_README" \
  && ! grep -q '<comment>-p</comment>' "$ROOT/post-install.txt" \
  && ! grep -qF -- '`-p`' "$ROOT/README.md" \
  && ! grep -qF -- '`-p`' "$REPO_README" \
  && ! grep -q 'shopware-acme' "$ROOT/post-install.txt" \
  && ! grep -q 'shopware-acme' "$ROOT/README.md" \
  && ! grep -q 'shopware-acme' "$REPO_README" \
  && ! grep -q 'COMPOSE_PROJECT_NAME=shopware-' "$ROOT/post-install.txt" \
  && ! grep -q 'COMPOSE_PROJECT_NAME=shopware-' "$ROOT/README.md" \
  && ! grep -q 'COMPOSE_PROJECT_NAME=shopware-' "$REPO_README" \
  && ! grep -q 'derived at runtime' "$ROOT/post-install.txt" \
  && ! grep -q 'derived at runtime' "$ROOT/README.md" \
  && ! grep -q 'derived at runtime' "$REPO_README" \
  && ! grep -q 'laptop and VPS same' "$ROOT/post-install.txt" \
  && ! grep -q 'laptop and VPS same' "$ROOT/README.md" \
  && ! grep -q 'laptop and VPS same' "$REPO_README" \
  && ! grep -q 'SHOPWARE_DEPLOY_ENV=live' "$ROOT/post-install.txt" \
  && ! grep -q 'SHOPWARE_DEPLOY_ENV=live' "$ROOT/README.md" \
  && ! grep -q 'SHOPWARE_DEPLOY_ENV=live' "$REPO_README"; then
  pass "recipe docs: shared .env has no deploy env / COMPOSE_PROJECT_NAME; .env.local + compose.override.yaml use acme-dev / acme-live"
else
  fail "recipe docs still mention dual-name / Flex SHOPWARE_DEPLOY_ENV=live or miss .env.local + override name"
fi

echo "==> recipe docs: DEPLOY_HEALTH_URL is post-deploy probe SoT"
if deploy_health_docs_ok "$ROOT/post-install.txt" \
  && deploy_health_docs_ok "$ROOT/README.md" \
  && deploy_health_docs_ok "$REPO_README"; then
  pass "recipe docs: DEPLOY_HEALTH_URL + APP_URL health-check default; live requires a resolvable URL"
else
  fail "recipe docs missing DEPLOY_HEALTH_URL contract or still treat SMOKE_URL as operator guidance"
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
    and "SHOPWARE_DEPLOY_ENV" not in env
    and env.get("SHOPWARE_DATA_BASE") == "/var/lib/shopware/data"
)
raise SystemExit(0 if ok else 1)
PY
then
  pass "manifest.json is copy-from-package + Flex env omits SHOPWARE_DEPLOY_ENV"
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

echo "==> dry-run does not write; real run comments COMPOSE_PROJECT_NAME; identity → .env.local + compose.override.yaml"
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
  && printf '%s' "$out" | grep -q 'IMAGE=ghcr.io/example/acme' \
  && printf '%s' "$out" | grep -q 'APP_SECRET' \
  && ! printf '%s' "$out" | grep -q -- '--vps' \
  && ! printf '%s' "$out" | grep -q 'generate-app-secret' \
  && ! printf '%s' "$out" | grep -q 'set APP_SECRET' \
  && ! printf '%s' "$out" | grep -q 'oldsecret' \
  && ! printf '%s' "$out" | grep -q 'shopware-acme'; then
  pass "dry-run summary sets shop id + image and strips COMPOSE_PROJECT_NAME without --vps"
else
  fail "dry-run rc=$rc out=$out"
fi
if cmp -s "$SHOP/.env" "$SHOP/.env.before"; then
  pass "dry-run does not write .env"
else
  fail "dry-run mutated .env"
fi
if [[ ! -f "$SHOP/.env.local" && ! -f "$SHOP/compose.override.yaml" ]]; then
  pass "dry-run does not write .env.local or compose.override.yaml"
else
  fail "dry-run mutated .env.local or compose.override.yaml"
fi

set +e
out="$(COMPOSE_DIR="$SHOP" fyrst-cli shopware env init --shop-id acme --env live --image ghcr.io/example/acme 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'SHOPWARE_SHOP_ID=acme' \
  && printf '%s' "$out" | grep -q 'commented' \
  && printf '%s' "$out" | grep -q 'COMPOSE_PROJECT_NAME' \
  && ! printf '%s' "$out" | grep -q -- '--vps' \
  && ! printf '%s' "$out" | grep -q 'shopware-acme'; then
  pass "real run summary sets shop id and comments COMPOSE_PROJECT_NAME"
else
  fail "real run rc=$rc out=$out"
fi

envf="$SHOP/.env"
if grep -q '^SHOPWARE_SHOP_ID=acme$' "$envf" \
  && grep -q '^IMAGE=ghcr.io/example/acme$' "$envf" \
  && no_deploy_env_in_dotenv "$envf"; then
  pass "real run writes shop id and IMAGE into .env; no env-specific SHOPWARE_DEPLOY_ENV there"
else
  fail "real run SoT keys: $(grep -E '^(SHOPWARE_|IMAGE=)' "$envf" || true)"
fi
if [[ -f "$SHOP/.env.local" ]] && local_project_identity "$SHOP" live acme-live \
  && ! grep -q 'shopware-acme' "$SHOP/.env.local"; then
  pass "real run writes SHOPWARE_DEPLOY_ENV=live and COMPOSE_PROJECT_NAME=acme-live into .env.local; override name: acme-live"
else
  fail "real run identity: local=$(cat "$SHOP/.env.local" 2>/dev/null || true) override=$(cat "$SHOP/compose.override.yaml" 2>/dev/null || true)"
fi
if grep -q '^APP_URL=https://keep.example$' "$envf" \
  && grep -q '^MYSQL_PASSWORD=keepme$' "$envf" \
  && grep -q '^APP_SECRET=oldsecret$' "$envf"; then
  pass "does not clobber existing APP_URL / MYSQL_PASSWORD / APP_SECRET"
else
  fail "clobbered operator secrets"
fi
if grep -q '^# COMPOSE_PROJECT_NAME=sw-shop-acme' "$envf" \
  && ! grep -q -- '--vps' "$envf" \
  && ! grep -q '^COMPOSE_PROJECT_NAME=' "$envf" \
  && ! grep -q '^COMPOSE_PROJECT_NAME=$' "$envf" \
  && ! grep -q 'shopware-acme' "$envf"; then
  pass "comments create’s COMPOSE_PROJECT_NAME and does not write COMPOSE_PROJECT_NAME into .env"
else
  fail "did not comment COMPOSE_PROJECT_NAME correctly: $(grep COMPOSE_PROJECT_NAME "$envf" || true)"
fi
if grep -q '^HTTP_PORT=' "$envf" && grep -q '^MYSQL_DATABASE=' "$envf"; then
  pass "merged missing keys from .env.example"
else
  fail "did not merge missing keys from .env.example"
fi
if grep -q '^###> fyrst/shopware-cd ###$' "$envf" \
  && grep -A3 '^###> fyrst/shopware-cd ###$' "$envf" | grep -q '^SHOPWARE_SHOP_ID=acme$' \
  && ! grep -A5 '^###> fyrst/shopware-cd ###$' "$envf" | grep -qE '^SHOPWARE_DEPLOY_ENV=.+$'; then
  pass "updates shop id inside the Flex marker block; no deploy env there"
else
  fail "Flex marker block not updated: $(sed -n '/###> fyrst/,/###</p' "$envf" || true)"
fi

echo "==> leftover Flex SHOPWARE_DEPLOY_ENV in .env is not left env-specific"
LEFTOVER="$TMP/leftover-flex"
mkdir -p "$LEFTOVER"
write_stub_env_example "$LEFTOVER"
cat >"$LEFTOVER/.env" <<'EOF'
SHOPWARE_SHOP_ID=
###> fyrst/shopware-cd ###
SHOPWARE_SHOP_ID=
SHOPWARE_DEPLOY_ENV=live
SHOPWARE_DATA_BASE=/var/lib/shopware/data
###< fyrst/shopware-cd ###
EOF
set +e
out="$(COMPOSE_DIR="$LEFTOVER" fyrst-cli shopware env init --shop-id acme --env staging 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && no_deploy_env_in_dotenv "$LEFTOVER/.env" \
  && grep -q '^SHOPWARE_SHOP_ID=acme$' "$LEFTOVER/.env" \
  && local_project_identity "$LEFTOVER" staging acme-staging; then
  pass "migrates leftover Flex SHOPWARE_DEPLOY_ENV out of .env; .env.local + override use acme-staging"
else
  fail "leftover Flex deploy env rc=$rc env=$(grep SHOPWARE_DEPLOY_ENV "$LEFTOVER/.env" || true) local=$(cat "$LEFTOVER/.env.local" 2>/dev/null || true) override=$(cat "$LEFTOVER/compose.override.yaml" 2>/dev/null || true) out=$out"
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
  && no_deploy_env_in_dotenv "$COPY_SHOP/.env" \
  && local_project_identity "$COPY_SHOP" staging widgets-staging \
  && ! grep -q '^COMPOSE_PROJECT_NAME=' "$COPY_SHOP/.env"; then
  pass "creates .env from .env.example; --shop-id in .env; widgets-staging in .env.local + override"
else
  fail "copy-from-example rc=$rc out=$out local=$(cat "$COPY_SHOP/.env.local" 2>/dev/null || true) override=$(cat "$COPY_SHOP/compose.override.yaml" 2>/dev/null || true)"
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
APP_SECRET=
APP_URL=
EOF
printf 'SHOPWARE_DEPLOY_ENV=staging\n' >"$KEEP/.env.local"
write_stub_env_example "$KEEP"
set +e
out="$(COMPOSE_DIR="$KEEP" fyrst-cli shopware env init 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q '^SHOPWARE_SHOP_ID=acme$' "$KEEP/.env" \
  && no_deploy_env_in_dotenv "$KEEP/.env" \
  && local_project_identity "$KEEP" staging acme-staging \
  && ! grep -q '^COMPOSE_PROJECT_NAME=' "$KEEP/.env"; then
  pass "keeps existing shop id in .env; writes acme-staging into .env.local + override; no COMPOSE_PROJECT_NAME in .env"
else
  fail "keep existing rc=$rc out=$out env=$(cat "$KEEP/.env") local=$(cat "$KEEP/.env.local" 2>/dev/null || true) override=$(cat "$KEEP/compose.override.yaml" 2>/dev/null || true)"
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

echo "==> laptop env init also comments COMPOSE_PROJECT_NAME; local name widgets-dev"
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
if [[ "$rc" -eq 0 ]] && grep -q '^# COMPOSE_PROJECT_NAME=sw-shop-widgets' "$LAP/.env" \
  && no_deploy_env_in_dotenv "$LAP/.env" \
  && local_project_identity "$LAP" dev widgets-dev \
  && ! grep -q '^COMPOSE_PROJECT_NAME=' "$LAP/.env" \
  && printf '%s' "$out" | grep -q 'commented' \
  && ! printf '%s' "$out" | grep -q -- '--vps' \
  && ! printf '%s' "$out" | grep -q 'shopware-widgets'; then
  pass "laptop env init comments create’s COMPOSE_PROJECT_NAME; .env.local + override use widgets-dev"
else
  fail "laptop strip rc=$rc out=$out env=$(grep -E 'COMPOSE_PROJECT_NAME|SHOPWARE_DEPLOY_ENV' "$LAP/.env" || true) local=$(cat "$LAP/.env.local" 2>/dev/null || true) override=$(cat "$LAP/compose.override.yaml" 2>/dev/null || true)"
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

echo "==> strip COMPOSE_PROJECT_NAME is idempotent (already commented)"
set +e
out="$(COMPOSE_DIR="$SHOP" fyrst-cli shopware env init --shop-id acme 2>&1)"
rc=$?
set -e
count="$(grep -c '^# COMPOSE_PROJECT_NAME=sw-shop-acme' "$SHOP/.env" || true)"
live_count=0
cpn_count=0
name_count=0
if [[ -f "$SHOP/.env.local" ]]; then
  live_count="$(grep -c '^SHOPWARE_DEPLOY_ENV=live$' "$SHOP/.env.local" || true)"
  cpn_count="$(grep -c '^COMPOSE_PROJECT_NAME=acme-live$' "$SHOP/.env.local" || true)"
fi
if [[ -f "$SHOP/compose.override.yaml" ]]; then
  name_count="$(grep -cE "^name:[[:space:]]*['\"]?acme-live['\"]?[[:space:]]*$" "$SHOP/compose.override.yaml" || true)"
fi
if [[ "$rc" -eq 0 && "$count" -eq 1 && "$live_count" -eq 1 && "$cpn_count" -eq 1 && "$name_count" -eq 1 ]] \
  && no_deploy_env_in_dotenv "$SHOP/.env" \
  && ! grep -q '^COMPOSE_PROJECT_NAME=' "$SHOP/.env" \
  && ! printf '%s' "$out" | grep -q -- '--vps'; then
  pass "second env init does not double-comment COMPOSE_PROJECT_NAME or duplicate .env.local / override identity"
else
  fail "idempotent strip rc=$rc count=$count live_count=$live_count cpn_count=$cpn_count name_count=$name_count out=$out"
fi

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nAll init-env checks passed.\n'
