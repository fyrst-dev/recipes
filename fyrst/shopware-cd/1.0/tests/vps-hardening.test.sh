#!/usr/bin/env bash
# Acceptance checks for VPS production hardening + fyrst-cli lifecycle verbs.
# Overlay files live in the package; this recipe only keeps Flex metadata.
# Behavioral checks need fyrst-cli 0.1.0+. No Docker required for most.
#   bash fyrst/shopware-cd/1.0/tests/vps-hardening.test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=fixtures.sh
source "$(dirname "$0")/fixtures.sh"
FAILS=0

pass() { printf 'ok  %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

require_fyrst_cli

echo "==> thin recipe (no overlay tree, no wrappers)"
if [[ -e "$ROOT/root" ]]; then
  fail "root/ still present"
else
  pass "root/ removed"
fi
for s in init-env.sh vps-release.sh vps-rollback.sh sync-runtime.sh \
  sync-runtime-local.sh backup-runtime.sh lib/fyrst-cli.sh lib/dispatch.sh \
  sync.env.example backup.env.example
do
  if [[ -e "$ROOT/$s" || -e "$ROOT/root/deploy/$s" ]]; then
    fail "wrapper still present $s"
  else
    pass "removed $s"
  fi
done
if compgen -G "$ROOT/*.sh" >/dev/null || [[ -d "$ROOT/deploy" ]]; then
  fail "recipe still ships shell wrappers"
else
  pass "no deploy/*.sh or deploy/"
fi

echo "==> recipe docs"
for needle in \
  'IMAGE_TAG=$(cat .previous-tag) fyrst-cli shopware deploy rollback' \
  'fyrst-cli shopware backup' \
  'deploy/edge/Caddyfile' \
  'fyrst-cli'
do
  if grep -q "$needle" "$ROOT/post-install.txt"; then
    pass "post-install mentions ${needle}"
  else
    fail "post-install missing ${needle}"
  fi
done
if grep -q 'fyrst-cli shopware deploy rollback' "$ROOT/post-install.txt" \
  && grep -q 'fyrst-cli shopware backup' "$ROOT/post-install.txt"; then
  pass "post-install pointers"
else
  fail "post-install missing rollback/backup pointers"
fi
if grep -qi 'not a backup' "$ROOT/README.md" || grep -qi 'not a backup' "$ROOT/post-install.txt"; then
  pass "recipe docs say sync is not a backup"
else
  fail "recipe docs missing sync ≠ backup"
fi

echo "==> fixture (no docker; real fyrst-cli)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SHOP="$TMP/acme-live"
write_stub_compose "$SHOP"
cat >"$SHOP/.env" <<'EOF'
IMAGE=ghcr.io/example/acme
IMAGE_TAG=tag-b
SHOPWARE_SHOP_ID=acme
SHOPWARE_DEPLOY_ENV=live
MYSQL_USER=shopware
MYSQL_PASSWORD=s3cret-not-in-logs
MYSQL_ROOT_PASSWORD=root-not-in-logs
EOF
: >"$SHOP/.env.prod"

set +e
out="$(cd "$SHOP" && fyrst-cli shopware deploy rollback --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'No .previous-tag'; then
  pass "rollback refuses missing .previous-tag"
else
  fail "rollback missing tag rc=$rc out=$out"
fi

printf '\n' >"$SHOP/.previous-tag"
set +e
out="$(cd "$SHOP" && fyrst-cli shopware deploy rollback --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -qi 'empty'; then
  pass "rollback refuses empty .previous-tag"
else
  fail "rollback empty tag rc=$rc out=$out"
fi

printf 'tag-a\n' >"$SHOP/.previous-tag"
set +e
out="$(cd "$SHOP" && fyrst-cli shopware deploy rollback --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'tag-a' && printf '%s' "$out" | grep -q 'DRY-RUN' && printf '%s' "$out" | grep -q -- '--no-build'; then
  pass "rollback dry-run restores tag-a without docker"
else
  fail "rollback dry-run rc=$rc out=$out"
fi
if printf '%s' "$out" | grep -q -- '--pull never' && printf '%s' "$out" | grep -q -- '--no-build' && ! printf '%s' "$out" | grep -qE 'docker compose build|docker build '; then
  pass "rollback dry-run is pull-never / up --no-build only"
else
  fail "rollback dry-run must not rebuild images"
fi
if printf '%s' "$out" | grep -qE 'run --rm --no-build|[[:space:]]run --no-build'; then
  fail "rollback dry-run still uses compose run --no-build"
else
  pass "rollback dry-run does not pass run --no-build"
fi

echo "==> backup on live (#15)"
mkdir -p "$TMP/backups"
set +e
out="$(cd "$SHOP" && BACKUP_TARGET="$TMP/backups" BACKUP_KEEP_DAYS=14 fyrst-cli shopware backup create --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'live is allowed' && printf '%s' "$out" | grep -qv 'Refusing'; then
  pass "backup --dry-run runs on SHOPWARE_DEPLOY_ENV=live"
else
  fail "backup live rc=$rc out=$out"
fi
if printf '%s' "$out" | grep -q "$TMP/backups"; then
  pass "backup dry-run uses BACKUP_TARGET"
else
  fail "backup dry-run did not mention BACKUP_TARGET"
fi
if printf '%s' "$out" | grep -q 'shopware-cli project dump'; then
  pass "backup dry-run tells operator to dump with shopware-cli"
else
  fail "backup dry-run missing shopware-cli dump instruction"
fi

echo "==> retention prune"
KEEP_DIR="$TMP/backups/acme/live"
mkdir -p "$KEEP_DIR/20200101T020000Z" "$KEEP_DIR/20990101T020000Z"
echo old >"$KEEP_DIR/20200101T020000Z/db.sql.gz"
echo new >"$KEEP_DIR/20990101T020000Z/db.sql.gz"
set +e
out="$(cd "$SHOP" && BACKUP_TARGET="$TMP/backups" BACKUP_KEEP_DAYS=14 fyrst-cli shopware backup prune 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 && ! -d "$KEEP_DIR/20200101T020000Z" && -d "$KEEP_DIR/20990101T020000Z" ]]; then
  pass "prune deletes stamps older than BACKUP_KEEP_DAYS"
else
  fail "prune rc=$rc out=$out ls=$(ls "$KEEP_DIR" 2>/dev/null || true)"
fi

echo "==> sync restore still refuses live without override"
mkdir -p "$SHOP/var/runtime-sync"
set +e
out="$(cd "$SHOP" && fyrst-cli shopware sync apply --dry-run --snapshot-dir "$SHOP/var/runtime-sync" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'Refusing restore/sync on a live host'; then
  pass "sync restore still refuses live (not a backup)"
else
  fail "sync live restore rc=$rc out=$out"
fi

echo "==> HTTP probe against mock Shopware health path"
PY_SRV="$TMP/health_srv.py"
cat >"$PY_SRV" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?", 1)[0] == "/api/_info/health-check":
            self.send_response(200)
            self.end_headers()
            return
        self.send_response(502)
        self.end_headers()
    def log_message(self, *args):
        pass
HTTPServer(("127.0.0.1", 18080), H).serve_forever()
PY
python3 "$PY_SRV" &
srv_pid=$!
sleep 0.3
set +e
curl -fsS --max-time 4 http://127.0.0.1:18080/api/_info/health-check >/dev/null
hc=$?
curl -fsS --max-time 2 http://127.0.0.1:18080/ >/dev/null
root=$?
curl -fsS --max-time 2 http://127.0.0.1:18081/api/_info/health-check >/dev/null
down=$?
kill "$srv_pid" 2>/dev/null || true
wait "$srv_pid" 2>/dev/null || true
set -e
if [[ "$hc" -eq 0 ]]; then
  pass "curl probe succeeds on /api/_info/health-check"
else
  fail "curl probe failed on mock health path"
fi
if [[ "$root" -ne 0 ]]; then
  pass "curl probe fails when path is 502 (Caddy up, Shopware not)"
else
  fail "curl probe should fail on 502 /"
fi
if [[ "$down" -ne 0 ]]; then
  pass "curl probe fails when nothing listens on the port"
else
  fail "curl probe should fail when port is down"
fi

echo "==> live Compose profiles warning (#18)"
if grep -q 'COMPOSE_PROFILES=redis,worker,scheduler' "$ROOT/post-install.txt" \
  && grep -q 'auto-enable' "$ROOT/post-install.txt"; then
  pass "post-install mentions profiles"
else
  fail "post-install missing profiles"
fi

echo "==> SKIP_PULL / PULL_POLICY=never (same-host tag-and-load)"
if grep -q 'PULL_POLICY=never' "$ROOT/post-install.txt" \
  && grep -q 'SKIP_PULL=1' "$ROOT/post-install.txt"; then
  pass "post-install documents PULL_POLICY=never / SKIP_PULL=1"
else
  fail "docs missing PULL_POLICY=never / SKIP_PULL=1"
fi
set +e
out="$(cd "$SHOP" && SKIP_PULL=1 fyrst-cli shopware deploy release --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'DRY-RUN skip compose pull' \
  && printf '%s' "$out" | grep -q -- '--pull never' \
  && ! printf '%s' "$out" | grep -qE 'DRY-RUN .* pull$'; then
  pass "SKIP_PULL=1 dry-run skips compose pull and uses --pull never"
else
  fail "SKIP_PULL dry-run rc=$rc out=$out"
fi
set +e
out="$(cd "$SHOP" && fyrst-cli shopware deploy release --skip-pull --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'DRY-RUN skip compose pull'; then
  pass "--skip-pull dry-run skips compose pull"
else
  fail "--skip-pull dry-run rc=$rc out=$out"
fi

echo "==> COMPOSE_PROJECT_NAME create footgun"
if grep -q 'COMPOSE_PROJECT_NAME=sw-shop' "$ROOT/post-install.txt" \
  && grep -q 'COMPOSE_PROJECT_NAME=sw-shop' "$ROOT/README.md"; then
  pass "docs warn about create's COMPOSE_PROJECT_NAME=sw-shop-… line"
else
  fail "docs missing create COMPOSE_PROJECT_NAME=sw-shop-… warning"
fi
if grep -q 'does not delete it' "$ROOT/post-install.txt" \
  && grep -q 'does not delete it' "$ROOT/README.md"; then
  pass "docs say Flex does not delete create's COMPOSE_PROJECT_NAME"
else
  fail "docs missing do-not-auto-delete wording"
fi
if grep -q 'env init --vps' "$ROOT/post-install.txt" \
  && grep -q 'env init --vps' "$ROOT/README.md"; then
  pass "docs point at fyrst-cli shopware env init --vps for the VPS footgun"
else
  fail "docs missing env init --vps"
fi
if grep -q 'env init --shop-id' "$ROOT/post-install.txt"; then
  pass "post-install documents Flex env + env init --shop-id"
else
  fail "docs missing Flex env / env init --shop-id"
fi
printf 'COMPOSE_PROJECT_NAME=sw-shop-acme\n' >>"$SHOP/.env"
set +e
out="$(cd "$SHOP" && fyrst-cli shopware deploy release --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'overrides Compose name:' \
  && printf '%s' "$out" | grep -q 'sw-shop-acme'; then
  pass "deploy release warns when create's COMPOSE_PROJECT_NAME is set"
else
  fail "COMPOSE_PROJECT_NAME warning rc=$rc out=$out"
fi
sed -i '/^COMPOSE_PROJECT_NAME=sw-shop-acme$/d' "$SHOP/.env"

echo "==> create writes .shopware-project.yml (do not rename)"
if grep -q '.shopware-project.yml' "$ROOT/post-install.txt" \
  && grep -q 'do not rename' "$ROOT/post-install.txt" \
  && ! grep -q 'loads <comment>.shopware-project.yaml</comment> from create' "$ROOT/post-install.txt"; then
  pass "post-install says create writes .yml and both extensions are fine"
else
  fail "post-install still claims create always uses .yaml"
fi
if grep -q '.shopware-project.yml' "$ROOT/README.md" \
  && grep -q 'do not rename' "$ROOT/README.md"; then
  pass "recipe README documents create's .yml"
else
  fail "recipe README missing create .yml wording"
fi

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nAll vps-hardening checks passed.\n'
