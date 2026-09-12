#!/usr/bin/env bash
# Acceptance checks for VPS production hardening (#10, #13–#16).
# No Docker required. Run from anywhere:
#   bash fyrst/shopware-cd/1.0/tests/vps-hardening.test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="${ROOT}/root/deploy"
FAILS=0

pass() { printf 'ok  %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

assert_file() {
  if [[ -f "$1" ]]; then
    pass "exists $1"
  else
    fail "missing $1"
  fi
}

assert_exec() {
  if [[ -x "$1" ]]; then
    pass "executable $1"
  else
    fail "not executable $1"
  fi
}

echo "==> bash -n"
for s in \
  "$DEPLOY/lib/vps-common.sh" \
  "$DEPLOY/vps-release.sh" \
  "$DEPLOY/vps-rollback.sh" \
  "$DEPLOY/backup-runtime.sh" \
  "$DEPLOY/sync-runtime.sh" \
  "$DEPLOY/sync-runtime-local.sh"
do
  if bash -n "$s"; then
    pass "bash -n $(basename "$s")"
  else
    fail "bash -n $(basename "$s")"
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  echo "==> shellcheck"
  if shellcheck -x "$DEPLOY/vps-release.sh" "$DEPLOY/vps-rollback.sh" "$DEPLOY/backup-runtime.sh" "$DEPLOY/lib/vps-common.sh"; then
    pass "shellcheck release/rollback/backup/lib"
  else
    fail "shellcheck"
  fi
else
  echo "==> shellcheck not installed (bash -n only)"
fi

echo "==> named files"
assert_file "$DEPLOY/vps-rollback.sh"
assert_exec "$DEPLOY/vps-rollback.sh"
assert_exec "$DEPLOY/vps-release.sh"
assert_file "$DEPLOY/backup-runtime.sh"
assert_exec "$DEPLOY/backup-runtime.sh"
assert_file "$DEPLOY/backup-runtime.md"
assert_file "$DEPLOY/backup.env.example"
assert_file "$DEPLOY/edge/Caddyfile"
assert_file "$DEPLOY/edge/README.md"
assert_file "$DEPLOY/lib/vps-common.sh"

echo "==> healthcheck path (#14)"
if grep -q "php -r 'exit(0);'" "$DEPLOY/compose.yaml"; then
  fail "compose.yaml still uses php -r exit(0)"
else
  pass "compose.yaml no longer uses php -r exit(0)"
fi
if grep -q 'http://127.0.0.1:8000/api/_info/health-check' "$DEPLOY/compose.yaml"; then
  pass "compose.yaml probes /api/_info/health-check on 127.0.0.1:8000"
else
  fail "compose.yaml missing health path"
fi
if grep -q 'host.docker.internal\|network_mode: host' "$DEPLOY/compose.yaml"; then
  fail "compose.yaml healthcheck must not depend on host network"
else
  pass "healthcheck has no host-network dependency"
fi
if grep -q 'start_period: 120s' "$DEPLOY/compose.prod.yaml"; then
  pass "compose.prod.yaml longer start_period"
else
  fail "compose.prod.yaml missing longer start_period"
fi

echo "==> prod bind (#16)"
if grep -q 'ports: !override' "$DEPLOY/compose.prod.yaml" && grep -q '\${HTTP_BIND:-127.0.0.1}:${HTTP_PORT:-8000}:8000' "$DEPLOY/compose.prod.yaml"; then
  pass "prod publish is loopback by default (!override)"
else
  fail "compose.prod.yaml does not bind 127.0.0.1 with !override"
fi
if grep -Fq 'ports: []' "$DEPLOY/compose.prod.yaml"; then
  pass "mysql ports: [] in compose.prod.yaml"
else
  fail "mysql not unpublished in compose.prod.yaml"
fi
if grep -q 'shop.example.com' "$DEPLOY/edge/Caddyfile" && grep -q 'reverse_proxy 127.0.0.1:8000' "$DEPLOY/edge/Caddyfile"; then
  pass "copy-paste Caddyfile for one hostname"
else
  fail "edge Caddyfile missing hostname reverse_proxy"
fi

echo "==> docs"
for needle in \
  'IMAGE_TAG=$(cat .previous-tag) bash deploy/vps-rollback.sh' \
  'ROLLBACK_ON_SMOKE_FAIL' \
  'api/_info/health-check' \
  'backup-runtime.sh' \
  'Sync is not a backup' \
  'deploy/edge/Caddyfile'
do
  if grep -q "$needle" "$DEPLOY/README.md"; then
    pass "README mentions ${needle}"
  else
    fail "README missing ${needle}"
  fi
done
if grep -q 'vps-rollback.sh' "$ROOT/post-install.txt" && grep -q 'backup-runtime.sh' "$ROOT/post-install.txt"; then
  pass "post-install pointers"
else
  fail "post-install missing rollback/backup pointers"
fi
if grep -qi 'not a backup' "$DEPLOY/sync-runtime.md"; then
  pass "sync-runtime.md says sync is not a backup"
else
  fail "sync-runtime.md missing sync ≠ backup"
fi

echo "==> helper: rollback command + auto-rollback flag"
# shellcheck source=../root/deploy/lib/vps-common.sh
SCRIPT_DIR="$DEPLOY"
# shellcheck disable=SC1091
source "$DEPLOY/lib/vps-common.sh"
cmd="$(vps_rollback_command)"
if [[ "$cmd" == 'IMAGE_TAG=$(cat .previous-tag) bash deploy/vps-rollback.sh' ]]; then
  pass "printed rollback command matches issue #13"
else
  fail "rollback command is: $cmd"
fi

SHOPWARE_DEPLOY_ENV=live
unset ROLLBACK_ON_SMOKE_FAIL || true
if vps_should_auto_rollback; then
  pass "auto-rollback default ON for live"
else
  fail "auto-rollback should default on for live"
fi
SHOPWARE_DEPLOY_ENV=staging
if vps_should_auto_rollback; then
  fail "auto-rollback should default off for staging"
else
  pass "auto-rollback default OFF for staging"
fi
ROLLBACK_ON_SMOKE_FAIL=1
SHOPWARE_DEPLOY_ENV=staging
if vps_should_auto_rollback; then
  pass "ROLLBACK_ON_SMOKE_FAIL=1 enables staging"
else
  fail "explicit ROLLBACK_ON_SMOKE_FAIL=1 should enable"
fi
ROLLBACK_ON_SMOKE_FAIL=0
SHOPWARE_DEPLOY_ENV=live
if vps_should_auto_rollback; then
  fail "ROLLBACK_ON_SMOKE_FAIL=0 should disable live"
else
  pass "ROLLBACK_ON_SMOKE_FAIL=0 disables live"
fi
unset ROLLBACK_ON_SMOKE_FAIL || true

echo "==> fixture scripts (no docker)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SHOP="$TMP/acme-live"
mkdir -p "$SHOP/deploy"
cp "$DEPLOY/compose.yaml" "$DEPLOY/compose.prod.yaml" "$DEPLOY/compose.vps.yaml" "$SHOP/deploy/"
cp -a "$DEPLOY/lib" "$SHOP/deploy/"
cp "$DEPLOY/vps-release.sh" "$DEPLOY/vps-rollback.sh" "$DEPLOY/backup-runtime.sh" "$DEPLOY/sync-runtime.sh" "$SHOP/deploy/"
chmod +x "$SHOP/deploy/"*.sh
cat >"$SHOP/.env" <<'EOF'
IMAGE=ghcr.io/example/acme
IMAGE_TAG=tag-b
SHOPWARE_SHOP_ID=acme
SHOPWARE_DEPLOY_ENV=live
MYSQL_USER=shop
MYSQL_PASSWORD=shop
MYSQL_ROOT_PASSWORD=root
EOF
: >"$SHOP/.env.prod"

set +e
out="$(cd "$SHOP" && bash deploy/vps-rollback.sh --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'No .previous-tag'; then
  pass "rollback refuses missing .previous-tag"
else
  fail "rollback missing tag rc=$rc out=$out"
fi

printf '\n' >"$SHOP/.previous-tag"
set +e
out="$(cd "$SHOP" && bash deploy/vps-rollback.sh --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -qi 'empty'; then
  pass "rollback refuses empty .previous-tag"
else
  fail "rollback empty tag rc=$rc out=$out"
fi

printf 'tag-a\n' >"$SHOP/.previous-tag"
set +e
out="$(cd "$SHOP" && bash deploy/vps-rollback.sh --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'tag-a' && printf '%s' "$out" | grep -q 'DRY-RUN' && printf '%s' "$out" | grep -q -- '--no-build'; then
  pass "rollback dry-run restores tag-a without docker"
else
  fail "rollback dry-run rc=$rc out=$out"
fi
if printf '%s' "$out" | grep -q -- '--no-build' && ! printf '%s' "$out" | grep -qE 'docker compose build|docker build '; then
  pass "rollback dry-run is pull/--no-build only"
else
  fail "rollback dry-run must not rebuild images"
fi

echo "==> smoke-failure prints exact command"
printf 'tag-a\n' >"$SHOP/.deployed-tag"
# Force smoke fail by pointing SMOKE_URL at a closed port and skipping real compose:
# dry-run smoke always succeeds, so drive the hint function instead.
hint="$(vps_print_smoke_rollback_hint 'http://127.0.0.1:9' 2>&1 || true)"
if printf '%s' "$hint" | grep -Fq 'IMAGE_TAG=$(cat .previous-tag) bash deploy/vps-rollback.sh'; then
  pass "smoke-failure hint prints exact rollback command"
else
  fail "hint was: $hint"
fi

echo "==> backup on live (#15)"
mkdir -p "$TMP/backups"
set +e
out="$(cd "$SHOP" && BACKUP_TARGET="$TMP/backups" BACKUP_KEEP_DAYS=14 bash deploy/backup-runtime.sh backup --dry-run 2>&1)"
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

echo "==> retention prune"
KEEP_DIR="$TMP/backups/acme/live"
mkdir -p "$KEEP_DIR/20200101T020000Z" "$KEEP_DIR/20990101T020000Z"
echo old >"$KEEP_DIR/20200101T020000Z/db.sql.gz"
echo new >"$KEEP_DIR/20990101T020000Z/db.sql.gz"
set +e
out="$(cd "$SHOP" && BACKUP_TARGET="$TMP/backups" BACKUP_KEEP_DAYS=14 bash deploy/backup-runtime.sh prune 2>&1)"
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
out="$(cd "$SHOP" && bash deploy/sync-runtime.sh restore --dry-run --snapshot-dir "$SHOP/var/runtime-sync" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'Refusing restore/sync on a live host'; then
  pass "sync restore still refuses live (not a backup)"
else
  fail "sync live restore rc=$rc out=$out"
fi

echo "==> docker compose config (optional)"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  CFG="$TMP/compose-cfg"
  mkdir -p "$CFG/deploy"
  cp "$DEPLOY/compose.yaml" "$DEPLOY/compose.prod.yaml" "$DEPLOY/compose.vps.yaml" "$CFG/deploy/"
  cat >"$CFG/.env" <<'EOF'
IMAGE=ghcr.io/example/acme
IMAGE_TAG=deadbeef
SHOPWARE_SHOP_ID=acme
SHOPWARE_DEPLOY_ENV=live
MYSQL_USER=shop
MYSQL_PASSWORD=shop
MYSQL_ROOT_PASSWORD=root
EOF
  : >"$CFG/.env.prod"
  set +e
  (cd "$CFG" && docker compose --env-file .env -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml config --format json >"$CFG/out.json")
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]] && python3 - "$CFG/out.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ports = d["services"]["web"].get("ports") or []
ok = len(ports) == 1 and ports[0].get("host_ip") == "127.0.0.1"
mysql = d["services"]["mysql"].get("ports")
hc = (d["services"]["web"].get("healthcheck") or {}).get("test") or []
path_ok = any("api/_info/health-check" in str(x) for x in hc)
raise SystemExit(0 if ok and mysql in (None, []) and path_ok else 1)
PY
  then
    pass "merged compose: one 127.0.0.1:8000 mapping, mysql unpublished, health path set"
  else
    fail "merged compose ports/health not as required (rc=$rc)"
  fi
else
  echo "docker compose not available; skipped merge check"
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
# closed port
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

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nAll vps-hardening checks passed.\n'
