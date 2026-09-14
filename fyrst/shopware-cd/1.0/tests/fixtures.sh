# Shared shop stubs for fyrst-cli checks. Not a Flex overlay and not a
# second source of truth — overlay files live in fyrst/shopware-cd overlay/.

write_stub_compose() {
  local shop="$1"
  mkdir -p "$shop/deploy"
  local stub=$'services:\n  web:\n    image: ${IMAGE:-x}:${IMAGE_TAG:-latest}\n'
  printf '%s' "$stub" >"$shop/deploy/compose.yaml"
  printf '%s' "$stub" >"$shop/deploy/compose.prod.yaml"
  printf '%s' "$stub" >"$shop/deploy/compose.vps.yaml"
}

# Minimal .env.example for `fyrst-cli shopware env init` merge/copy checks.
write_stub_env_example() {
  cat >"$1/.env.example" <<'EOF'
HTTP_PORT=8000
MYSQL_DATABASE=shopware
APP_URL=
APP_SECRET=
MYSQL_PASSWORD=
EOF
}

require_fyrst_cli() {
  if ! command -v fyrst-cli >/dev/null 2>&1; then
    printf 'FAIL fyrst-cli 0.1.0+ is required. Install:\n' >&2
    printf '  curl -fsSL https://raw.githubusercontent.com/fyrst-dev/cli/main/scripts/install.sh | bash\n' >&2
    exit 1
  fi
}
