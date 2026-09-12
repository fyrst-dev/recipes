#!/usr/bin/env bash
# Opt-in sales_channel_domain rewrite after sync/restore (#17).
# Sourced by deploy/sync-runtime.sh. Safe to source from tests (no side effects).
#
# Shopware 6.x storefront/admin host matching uses sales_channel_domain.url.
# This helper rewrites that column only. It does not touch media CDN, plugin
# configs, APP_URL in .env, or payment/shipping webhook registrations.

# True when the operator opted in (either a single new origin or an old→new map).
sync_rewrite_requested() {
  [[ -n "${SYNC_REWRITE_APP_URL:-}" || -n "${SYNC_REWRITE_URL_MAP:-}" ]]
}

# Strip a single trailing slash from a URL origin/base (keep path slashes).
sync_rewrite_strip_trailing_slash() {
  local s=$1
  while [[ "$s" == */ && "$s" != *:// ]]; do
    s="${s%/}"
  done
  printf '%s' "$s"
}

# scheme://host[:port] from a URL. Empty if the value is not an absolute http(s) URL.
sync_rewrite_origin() {
  local url=$1
  if [[ "$url" =~ ^(https?)://([^/?#]+) ]]; then
    printf '%s://%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# Path (+ query/hash) after the origin, or empty. Leading slash kept when present.
sync_rewrite_path() {
  local url=$1
  local origin
  origin="$(sync_rewrite_origin "$url")" || { printf '%s' ""; return 0; }
  printf '%s' "${url#"$origin"}"
}

sync_rewrite_validate_http_url() {
  local label=$1
  local url=$2
  if [[ -z "$url" ]]; then
    printf 'ERROR: %s is empty\n' "$label" >&2
    return 1
  fi
  if [[ ! "$url" =~ ^https?://[^/?#]+ ]]; then
    printf 'ERROR: %s must be an absolute http(s) URL (got %q)\n' "$label" "$url" >&2
    return 1
  fi
  if [[ "$url" == *$'\n'* || "$url" == *$'\r'* ]]; then
    printf 'ERROR: %s contains a newline\n' "$label" >&2
    return 1
  fi
  return 0
}

# Parse SYNC_REWRITE_URL_MAP=old=new,old=new into parallel arrays (longest prefix first).
# Callers: SYNC_REWRITE_MAP_OLD / SYNC_REWRITE_MAP_NEW (namerefs via globals).
SYNC_REWRITE_MAP_OLD=()
SYNC_REWRITE_MAP_NEW=()

sync_rewrite_load_map() {
  SYNC_REWRITE_MAP_OLD=()
  SYNC_REWRITE_MAP_NEW=()
  local spec="${SYNC_REWRITE_URL_MAP:-}"
  [[ -z "$spec" ]] && return 0
  local IFS=','
  local -a parts=()
  # shellcheck disable=SC2206
  parts=($spec)
  local item old new
  for item in "${parts[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -z "$item" ]] && continue
    if [[ "$item" != *=* ]]; then
      printf 'ERROR: SYNC_REWRITE_URL_MAP entry %q is not old=new\n' "$item" >&2
      return 1
    fi
    old="${item%%=*}"
    new="${item#*=}"
    old="$(sync_rewrite_strip_trailing_slash "$old")"
    new="$(sync_rewrite_strip_trailing_slash "$new")"
    sync_rewrite_validate_http_url "SYNC_REWRITE_URL_MAP old" "$old" || return 1
    sync_rewrite_validate_http_url "SYNC_REWRITE_URL_MAP new" "$new" || return 1
    SYNC_REWRITE_MAP_OLD+=("$old")
    SYNC_REWRITE_MAP_NEW+=("$new")
  done
  # Longest old prefix first so https://shop.example.com/en wins over https://shop.example.com
  local i j
  local n=${#SYNC_REWRITE_MAP_OLD[@]}
  for ((i = 0; i < n; i++)); do
    for ((j = i + 1; j < n; j++)); do
      if [[ ${#SYNC_REWRITE_MAP_OLD[j]} -gt ${#SYNC_REWRITE_MAP_OLD[i]} ]]; then
        old="${SYNC_REWRITE_MAP_OLD[i]}"
        new="${SYNC_REWRITE_MAP_NEW[i]}"
        SYNC_REWRITE_MAP_OLD[i]="${SYNC_REWRITE_MAP_OLD[j]}"
        SYNC_REWRITE_MAP_NEW[i]="${SYNC_REWRITE_MAP_NEW[j]}"
        SYNC_REWRITE_MAP_OLD[j]="$old"
        SYNC_REWRITE_MAP_NEW[j]="$new"
      fi
    done
  done
}

sync_rewrite_validate_opts() {
  if [[ -n "${SYNC_REWRITE_APP_URL:-}" ]]; then
    local base
    base="$(sync_rewrite_strip_trailing_slash "$SYNC_REWRITE_APP_URL")"
    sync_rewrite_validate_http_url "SYNC_REWRITE_APP_URL" "$base" || return 1
  fi
  sync_rewrite_load_map
}

# Rewrite one sales_channel_domain.url. Prints the new URL (or the original if no rule matches).
sync_rewrite_apply_url() {
  local old=$1
  local i prefix new_prefix remainder new_url origin path base
  for i in "${!SYNC_REWRITE_MAP_OLD[@]}"; do
    prefix="${SYNC_REWRITE_MAP_OLD[$i]}"
    new_prefix="${SYNC_REWRITE_MAP_NEW[$i]}"
    if [[ "$old" == "$prefix" || "$old" == "$prefix/"* ]]; then
      remainder="${old#"$prefix"}"
      new_url="${new_prefix}${remainder}"
      printf '%s' "$new_url"
      return 0
    fi
  done
  if [[ -n "${SYNC_REWRITE_APP_URL:-}" ]]; then
    base="$(sync_rewrite_strip_trailing_slash "$SYNC_REWRITE_APP_URL")"
    origin="$(sync_rewrite_origin "$old")" || { printf '%s' "$old"; return 0; }
    path="$(sync_rewrite_path "$old")"
    printf '%s%s' "$base" "$path"
    return 0
  fi
  printf '%s' "$old"
}

sync_rewrite_sql_escape() {
  local s=$1
  s="${s//\\/\\\\}"
  s="${s//\'/\'\'}"
  printf '%s' "$s"
}

# stdin: one existing sales_channel_domain.url per line
# stdout: old<TAB>new for rows that change
# stderr: collisions / invalid URLs
# return 2 on collision
sync_rewrite_plan_from_urls() {
  local old new
  local -A seen_new=()
  local -A old_for_new=()
  local collision=0
  while IFS= read -r old || [[ -n "$old" ]]; do
    old="${old%$'\r'}"
    [[ -z "$old" ]] && continue
    new="$(sync_rewrite_apply_url "$old")"
    if [[ "$new" == "$old" ]]; then
      continue
    fi
    if [[ -n "${seen_new[$new]:-}" ]]; then
      printf 'ERROR: rewrite collision: %q and %q both become %q (sales_channel_domain.url is unique)\n' \
        "${old_for_new[$new]}" "$old" "$new" >&2
      collision=1
      continue
    fi
    seen_new[$new]=1
    old_for_new[$new]="$old"
    printf '%s\t%s\n' "$old" "$new"
  done
  if [[ "$collision" -eq 1 ]]; then
    return 2
  fi
  return 0
}

sync_rewrite_update_sql() {
  local old=$1
  local new=$2
  printf "UPDATE sales_channel_domain SET url = '%s', updated_at = NOW(3) WHERE url = '%s';\n" \
    "$(sync_rewrite_sql_escape "$new")" \
    "$(sync_rewrite_sql_escape "$old")"
}

# Hard refuse rewrite on a live consumer. SYNC_ALLOW_LIVE_RESTORE=1 does NOT bypass this.
# Optional args override env (tests): $1=SYNC_ENV $2=SHOPWARE_DEPLOY_ENV $3=checkout basename $4=hostname
sync_rewrite_is_live_consumer() {
  local sync_lc deploy_lc base_lc host_lc
  sync_lc="$(printf '%s' "${1:-${SYNC_ENV:-}}" | tr '[:upper:]' '[:lower:]')"
  deploy_lc="$(printf '%s' "${2:-${SHOPWARE_DEPLOY_ENV:-}}" | tr '[:upper:]' '[:lower:]')"
  base_lc="$(printf '%s' "${3:-}" | tr '[:upper:]' '[:lower:]')"
  host_lc="$(printf '%s' "${4:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$sync_lc" == "live" ]] && return 0
  [[ "$deploy_lc" == "live" ]] && return 0
  [[ "$base_lc" == "live" ]] && return 0
  [[ "$host_lc" == "live" ]] && return 0
  return 1
}

sync_rewrite_assert_not_live() {
  local sync_env="${1:-${SYNC_ENV:-}}"
  local deploy_env="${2:-${SHOPWARE_DEPLOY_ENV:-}}"
  local checkout="${3:-}"
  local host="${4:-}"
  if sync_rewrite_is_live_consumer "$sync_env" "$deploy_env" "$checkout" "$host"; then
    printf 'ERROR: Refusing sales-channel domain rewrite on a live host (SYNC_ENV=%s, SHOPWARE_DEPLOY_ENV=%s). Unset SYNC_REWRITE_APP_URL / SYNC_REWRITE_URL_MAP. Rewrite is never allowed on live (SYNC_ALLOW_LIVE_RESTORE=1 does not bypass this).\n' \
      "${sync_env:-unset}" "${deploy_env:-unset}" >&2
    return 1
  fi
  return 0
}
