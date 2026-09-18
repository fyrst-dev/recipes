#!/usr/bin/env bash
# Recipe contract: no root/ overlay, no bash wrappers, fyrst-cli only.
#   bash fyrst/shopware-cd/1.0/tests/wrappers.test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=fixtures.sh
source "$(dirname "$0")/fixtures.sh"
FAILS=0

pass() { printf 'ok  %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

require_fyrst_cli

echo "==> private recipe is thin (no second overlay source)"
if [[ -e "$ROOT/root" ]]; then
  fail "root/ still present"
else
  pass "root/ removed"
fi
if [[ -e "$ROOT/deploy" ]] || compgen -G "$ROOT/*.sh" >/dev/null; then
  fail "recipe still ships deploy/ or bash wrappers"
else
  pass "no recipe-level deploy/ or *.sh"
fi
if python3 - "$ROOT/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
ok = (
    m.get("copy-from-package") == {"overlay/": ""}
    and "copy-from-recipe" not in m
)
raise SystemExit(0 if ok else 1)
PY
then
  pass "manifest.json is copy-from-package overlay/ only"
else
  fail "manifest.json still has copy-from-recipe or wrong copy-from-package"
fi

echo "==> wrappers and dispatcher stay gone"
for s in init-env.sh vps-release.sh vps-rollback.sh sync-runtime.sh \
  sync-runtime-local.sh backup-runtime.sh lib/fyrst-cli.sh lib/dispatch.sh \
  .shellcheckrc sync.env.example backup.env.example
do
  if [[ -e "$ROOT/$s" || -e "$ROOT/root/deploy/$s" ]]; then
    fail "still present $s"
  else
    pass "removed $s"
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
if fyrst_cli_has_deploy_health; then
  set +e
  out="$(fyrst-cli shopware deploy release --help 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q -- '--allow-no-deploy-health'; then
    pass "deploy release --help documents --allow-no-deploy-health"
  else
    fail "deploy release --help missing --allow-no-deploy-health rc=$rc out=$out"
  fi
fi

echo "==> env init comments COMPOSE_PROJECT_NAME; --vps gone"
set +e
out="$(fyrst-cli shopware env init --help 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && ! printf '%s' "$out" | grep -q -- '--vps' \
  && printf '%s' "$out" | grep -q 'COMPOSE_PROJECT_NAME'; then
  pass "env init --help has no --vps; documents COMPOSE_PROJECT_NAME"
else
  fail "env init --help still lists --vps rc=$rc out=$out"
fi
set +e
out="$(fyrst-cli shopware env init --vps 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -qiE 'unexpected argument|unexpected'; then
  pass "env init rejects --vps"
else
  fail "env init still accepts --vps rc=$rc out=$out"
fi

echo "==> sync local --data all stays rejected"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SHOP="$TMP/laptop"
write_stub_compose "$SHOP"
cat >"$SHOP/.env" <<'EOF'
IMAGE=ghcr.io/example/acme
IMAGE_TAG=tag-b
SHOPWARE_SHOP_ID=acme
EOF
printf 'SHOPWARE_DEPLOY_ENV=dev\n' >"$SHOP/.env.local"
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

echo "==> recipe docs use lifecycle verbs"
if grep -q 'fyrst-cli shopware deploy release' "$ROOT/post-install.txt" \
  && grep -q 'fyrst-cli shopware backup create' "$ROOT/post-install.txt" \
  && grep -q 'fyrst-cli shopware sync local' "$ROOT/post-install.txt" \
  && grep -q 'refused' "$ROOT/post-install.txt" \
  && ! grep -q 'bash ./deploy/vps-release.sh' "$ROOT/post-install.txt" \
  && ! grep -q 'bash deploy/sync-runtime.sh' "$ROOT/post-install.txt" \
  && ! grep -q 'generate-app-secret' "$ROOT/post-install.txt" \
  && ! grep -q 'generate-app-secret' "$ROOT/README.md" \
  && ! grep -q -- '--vps' "$ROOT/post-install.txt" \
  && ! grep -q -- '--vps' "$ROOT/README.md" \
  && ! grep -q 'copy-from-recipe' "$ROOT/manifest.json" \
  && grep -q 'copy-from-package' "$ROOT/README.md"; then
  pass "recipe docs are fyrst-cli lifecycle verbs (no wrappers / --vps / copy-from-recipe)"
else
  fail "recipe docs still document bash wrappers, copy-from-recipe, --vps, or --generate-app-secret"
fi

echo "==> recipe docs: DEPLOY_HEALTH_URL is post-deploy probe SoT (SMOKE_URL removed)"
REPO_README="$(cd "$ROOT/../../.." && pwd)/README.md"
if deploy_health_docs_ok "$ROOT/post-install.txt" \
  && deploy_health_docs_ok "$ROOT/README.md" \
  && deploy_health_docs_ok "$REPO_README" \
  && ! grep -qiE 'deprecated alias|still accepted|still works|Optional [`'"'"'<]*SMOKE_URL|SMOKE_URL still' "$ROOT/post-install.txt" \
  && ! grep -qiE 'deprecated alias|still accepted|still works|Optional [`'"'"'<]*SMOKE_URL|SMOKE_URL still' "$ROOT/README.md" \
  && ! grep -qiE 'deprecated alias|still accepted|still works|Optional [`'"'"'<]*SMOKE_URL|SMOKE_URL still' "$REPO_README"; then
  pass "recipe docs: DEPLOY_HEALTH_URL SoT; live requires a resolvable URL; SMOKE_URL removed"
else
  fail "recipe docs missing DEPLOY_HEALTH_URL contract or still treat SMOKE_URL as operator guidance"
fi

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%d check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nAll overlay fyrst-cli checks passed.\n'
