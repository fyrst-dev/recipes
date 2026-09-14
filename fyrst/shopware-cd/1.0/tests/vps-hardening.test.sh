#!/usr/bin/env bash
# Acceptance checks for VPS production hardening + fyrst-cli wrappers.
# Behavioral script checks need fyrst-cli 0.1.0+. No Docker required for most.
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

if ! command -v fyrst-cli >/dev/null 2>&1; then
  printf 'FAIL fyrst-cli 0.1.0+ is required (wrappers exec it). Install:\n' >&2
  printf '  curl -fsSL https://raw.githubusercontent.com/fyrst-dev/cli/main/scripts/install.sh | bash\n' >&2
  exit 1
fi

echo "==> bash -n"
for s in \
  "$DEPLOY/lib/fyrst-cli.sh" \
  "$DEPLOY/lib/dispatch.sh" \
  "$DEPLOY/vps-release.sh" \
  "$DEPLOY/vps-rollback.sh" \
  "$DEPLOY/backup-runtime.sh" \
  "$DEPLOY/sync-runtime.sh" \
  "$DEPLOY/sync-runtime-local.sh" \
  "$DEPLOY/init-env.sh"
do
  if bash -n "$s"; then
    pass "bash -n $(basename "$s")"
  else
    fail "bash -n $(basename "$s")"
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  echo "==> shellcheck"
  if shellcheck -x "$DEPLOY/vps-release.sh" "$DEPLOY/vps-rollback.sh" \
    "$DEPLOY/backup-runtime.sh" "$DEPLOY/init-env.sh" \
    "$DEPLOY/sync-runtime.sh" "$DEPLOY/sync-runtime-local.sh" \
    "$DEPLOY/lib/fyrst-cli.sh" "$DEPLOY/lib/dispatch.sh"; then
    pass "shellcheck wrappers + helper"
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
assert_file "$DEPLOY/lib/fyrst-cli.sh"
assert_file "$DEPLOY/lib/dispatch.sh"
assert_exec "$DEPLOY/init-env.sh"

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
  'deploy/edge/Caddyfile' \
  'fyrst-cli'
do
  if grep -q "$needle" "$DEPLOY/README.md"; then
    pass "README mentions ${needle}"
  else
    fail "README missing ${needle}"
  fi
done
if grep -q 'vps-rollback.sh' "$ROOT/post-install.txt" && grep -q 'backup-runtime.sh' "$ROOT/post-install.txt" \
  && grep -q 'fyrst-cli' "$ROOT/post-install.txt"; then
  pass "post-install pointers"
else
  fail "post-install missing rollback/backup/fyrst-cli pointers"
fi
if grep -qi 'not a backup' "$DEPLOY/sync-runtime.md"; then
  pass "sync-runtime.md says sync is not a backup"
else
  fail "sync-runtime.md missing sync ≠ backup"
fi

echo "==> fixture scripts (no docker; real fyrst-cli)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SHOP="$TMP/acme-live"
mkdir -p "$SHOP/deploy"
cp "$DEPLOY/compose.yaml" "$DEPLOY/compose.prod.yaml" "$DEPLOY/compose.vps.yaml" "$SHOP/deploy/"
mkdir -p "$SHOP/deploy/lib"
cp "$DEPLOY/lib/"*.sh "$SHOP/deploy/lib/"
cp "$DEPLOY/vps-release.sh" "$DEPLOY/vps-rollback.sh" "$DEPLOY/backup-runtime.sh" "$DEPLOY/sync-runtime.sh" "$SHOP/deploy/"
chmod +x "$SHOP/deploy/"*.sh
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
MYSQL_USER=shopware
MYSQL_PASSWORD=s3cret-not-in-logs
MYSQL_ROOT_PASSWORD=root-not-in-logs
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
web_pull = (d["services"]["web"].get("pull_policy") or "").lower()
setup_pull = (d["services"]["setup"].get("pull_policy") or "").lower()
raise SystemExit(0 if ok and mysql in (None, []) and path_ok and web_pull == "always" and setup_pull == "always" else 1)
PY
  then
    pass "merged compose: one 127.0.0.1:8000 mapping, mysql unpublished, health path set, pull_policy always"
  else
    fail "merged compose ports/health/pull_policy not as required (rc=$rc)"
  fi
  set +e
  (cd "$CFG" && PULL_POLICY=never docker compose --env-file .env -f deploy/compose.yaml -f deploy/compose.prod.yaml -f deploy/compose.vps.yaml config --format json >"$CFG/out-never.json")
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]] && python3 - "$CFG/out-never.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
web_pull = (d["services"]["web"].get("pull_policy") or "").lower()
setup_pull = (d["services"]["setup"].get("pull_policy") or "").lower()
raise SystemExit(0 if web_pull == "never" and setup_pull == "never" else 1)
PY
  then
    pass "PULL_POLICY=never interpolates pull_policy never on image services"
  else
    fail "PULL_POLICY=never did not change pull_policy (rc=$rc)"
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
if grep -q 'Uncomment on live' "$ROOT/root/.env.example" \
  && grep -q 'COMPOSE_PROFILES=redis,worker,scheduler' "$ROOT/root/.env.example"; then
  pass ".env.example states live COMPOSE_PROFILES recommendation"
else
  fail ".env.example missing live profiles recommendation"
fi
if grep -q 'COMPOSE_PROFILES=redis,worker,scheduler' "$ROOT/post-install.txt" \
  && grep -q 'auto-enable' "$DEPLOY/README.md"; then
  pass "post-install + deploy README mention profiles"
else
  fail "post-install / README missing profiles"
fi

echo "==> wrappers do not pass compose run --no-build"
if grep -RIn --include='*.sh' -- 'run --rm --no-build' "$DEPLOY" \
  | grep -v ':[[:space:]]*#' \
  || grep -RIn --include='*.sh' -- 'run --no-build' "$DEPLOY" \
  | grep -v ':[[:space:]]*#'; then
  fail "compose run still uses --no-build"
else
  pass "no compose run --no-build in deploy scripts"
fi

echo "==> SKIP_PULL / PULL_POLICY=never (same-host tag-and-load)"
if grep -q 'pull_policy: ${PULL_POLICY:-always}' "$DEPLOY/compose.vps.yaml"; then
  pass "compose.vps.yaml interpolates PULL_POLICY (default always)"
else
  fail "compose.vps.yaml missing PULL_POLICY interpolation"
fi
if grep -q 'PULL_POLICY=never' "$ROOT/root/.env.example" \
  && grep -q 'SKIP_PULL=1' "$ROOT/root/.env.example" \
  && grep -q 'PULL_POLICY=never' "$DEPLOY/README.md"; then
  pass ".env.example + deploy README document PULL_POLICY=never / SKIP_PULL=1"
else
  fail "docs missing PULL_POLICY=never / SKIP_PULL=1"
fi
set +e
out="$(cd "$SHOP" && SKIP_PULL=1 bash deploy/vps-release.sh --dry-run 2>&1)"
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
out="$(cd "$SHOP" && bash deploy/vps-release.sh --skip-pull --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'DRY-RUN skip compose pull'; then
  pass "--skip-pull dry-run skips compose pull"
else
  fail "--skip-pull dry-run rc=$rc out=$out"
fi

echo "==> COMPOSE_PROJECT_NAME create footgun"
if grep -q 'COMPOSE_PROJECT_NAME=sw-shop' "$ROOT/root/.env.example" \
  && grep -q 'COMPOSE_PROJECT_NAME=sw-shop' "$ROOT/post-install.txt" \
  && grep -q 'COMPOSE_PROJECT_NAME=sw-shop' "$DEPLOY/README.md"; then
  pass "docs warn about create's COMPOSE_PROJECT_NAME=sw-shop-… line"
else
  fail "docs missing create COMPOSE_PROJECT_NAME=sw-shop-… warning"
fi
if grep -q 'does not delete it' "$ROOT/post-install.txt" \
  && grep -q 'does not delete it' "$DEPLOY/README.md"; then
  pass "docs say Flex does not delete create's COMPOSE_PROJECT_NAME"
else
  fail "docs missing do-not-auto-delete wording"
fi
if grep -q 'init-env.sh --vps' "$ROOT/post-install.txt" \
  && grep -q 'init-env.sh --vps' "$DEPLOY/README.md" \
  && grep -q 'init-env.sh --vps' "$ROOT/root/.env.example"; then
  pass "docs point at deploy/init-env.sh --vps for the VPS footgun"
else
  fail "docs missing deploy/init-env.sh --vps"
fi
if grep -q 'init-env.sh --shop-id' "$ROOT/post-install.txt" \
  && grep -q '###> fyrst/shopware-cd ###' "$DEPLOY/README.md"; then
  pass "post-install + deploy README document Flex env + init-env --shop-id"
else
  fail "docs missing Flex env / init-env --shop-id"
fi
printf 'COMPOSE_PROJECT_NAME=sw-shop-acme\n' >>"$SHOP/.env"
set +e
out="$(cd "$SHOP" && bash deploy/vps-release.sh --dry-run 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'overrides Compose name:' \
  && printf '%s' "$out" | grep -q 'sw-shop-acme'; then
  pass "vps-release warns when create's COMPOSE_PROJECT_NAME is set"
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
CD_YAML="$ROOT/root/.github/workflows/cd.yaml"
GL_YAML="$ROOT/root/.gitlab-ci.yaml"
for f in "$CD_YAML" "$GL_YAML"; do
  if grep -n 'SHOPWARE_PACKAGES_TOKEN' "$f" | grep -Eiq 'required'; then
    fail "$(basename "$f") still lists SHOPWARE_PACKAGES_TOKEN as required"
  else
    pass "$(basename "$f") does not call SHOPWARE_PACKAGES_TOKEN required"
  fi
  if grep -q 'set only if the shop uses packages.shopware.com' "$f"; then
    pass "$(basename "$f") says set only if the shop uses packages.shopware.com"
  else
    fail "$(basename "$f") missing optional packages.shopware.com wording"
  fi
done
if grep -A5 'Required secrets' "$CD_YAML" | grep -q 'SHOPWARE_PACKAGES_TOKEN'; then
  fail "cd.yaml still lists SHOPWARE_PACKAGES_TOKEN under Required secrets"
else
  pass "cd.yaml does not list packages token under Required secrets"
fi
if grep -Fq 'packages_token=${{ secrets.SHOPWARE_PACKAGES_TOKEN }}' "$CD_YAML"; then
  pass "GitHub still passes packages_token BuildKit secret (empty is fine)"
else
  fail "GitHub dropped packages_token secret"
fi
if grep -q -- '--secret id=packages_token,env=SHOPWARE_PACKAGES_TOKEN' "$GL_YAML" \
  && grep -q 'SHOPWARE_PACKAGES_TOKEN:-' "$GL_YAML"; then
  pass "GitLab still passes packages_token (empty default)"
else
  fail "GitLab dropped empty-ok packages_token handling"
fi
if grep -Eiq 'SHOPWARE_PACKAGES_TOKEN.? is optional' "$DEPLOY/README.md" \
  && grep -q 'packages.shopware.com' "$DEPLOY/README.md"; then
  pass "deploy README marks SHOPWARE_PACKAGES_TOKEN optional"
else
  fail "deploy README missing optional SHOPWARE_PACKAGES_TOKEN wording"
fi
if grep -q 'SHOPWARE_PACKAGES_TOKEN is a CI secret' "$ROOT/root/.env.example" \
  && grep -q 'packages.shopware.com' "$ROOT/root/.env.example"; then
  pass ".env.example documents packages token as optional CI secret"
else
  fail ".env.example missing optional SHOPWARE_PACKAGES_TOKEN wording"
fi

echo "==> managed host planned, no failing stub (#19)"
if grep -q 'deploy_managed:' "$ROOT/root/.github/workflows/cd.yaml" \
  || grep -q 'deploy_managed:' "$ROOT/root/.gitlab-ci.yaml"; then
  fail "CI still has a deploy_managed job"
else
  pass "CI has no deploy_managed job"
fi
if grep -q 'vars.DEPLOY_TARGET != .managed' "$ROOT/root/.github/workflows/cd.yaml" \
  || grep -q 'DEPLOY_TARGET == "managed"' "$ROOT/root/.gitlab-ci.yaml"; then
  fail "CI still gates Compose deploy on DEPLOY_TARGET=managed"
else
  pass "Compose deploy is not skipped for a planned managed target"
fi
if grep -qi 'planned' "$DEPLOY/managed/README.md" \
  && grep -qi 'not implemented' "$DEPLOY/managed/README.md"; then
  pass "managed README is planned / not implemented"
else
  fail "managed README still reads as a supported path"
fi
if grep -q 'exit 1' "$DEPLOY/managed/README.md" && grep -q 'Replace this job' "$ROOT/root/.github/workflows/cd.yaml"; then
  fail "managed stub fail message still in CI"
else
  pass "CI does not pretend managed deploy works then fail"
fi

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nAll vps-hardening checks passed.\n'
