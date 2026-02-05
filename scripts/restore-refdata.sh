#!/usr/bin/env sh
set -eu

REFDATA_ADMIN_URL="${REFDATA_ADMIN_URL:-}"

if ! command -v curl >/dev/null 2>&1; then
  echo "Missing required command: curl" >&2
  exit 2
fi

pick_admin_url() {
  if [ -n "$REFDATA_ADMIN_URL" ]; then
    echo "$REFDATA_ADMIN_URL"
    return
  fi

  looks_like_refdata_dc1_primary() {
    body="$1"
    echo "$body" | grep -q "\"serviceId\":\"refdata-dc1\"" || return 1
    echo "$body" | grep -q "\"datacenter\":\"dc1\"" || return 1
    echo "$body" | grep -q "\"instanceRole\":\"primary\"" || return 1
    return 0
  }

  body_8082="$(curl -sS "http://localhost:8082/health" 2>/dev/null || true)"
  body_28082="$(curl -sS "http://localhost:28082/health" 2>/dev/null || true)"

  ok_8082=0
  ok_28082=0
  if [ -n "$body_8082" ] && looks_like_refdata_dc1_primary "$body_8082"; then ok_8082=1; fi
  if [ -n "$body_28082" ] && looks_like_refdata_dc1_primary "$body_28082"; then ok_28082=1; fi

  if [ "$ok_8082" -eq 1 ] && [ "$ok_28082" -eq 1 ]; then
    echo "ERROR: Both http://localhost:8082 and http://localhost:28082 look like the dc1 refdata primary." >&2
    echo "Stop one stack, or set REFDATA_ADMIN_URL explicitly." >&2
    exit 2
  fi

  if [ "$ok_8082" -eq 1 ]; then
    echo "http://localhost:8082/admin/active"
    return
  fi

  if [ "$ok_28082" -eq 1 ]; then
    echo "http://localhost:28082/admin/active"
    return
  fi

  echo "ERROR: Could not find the dc1 refdata primary on http://localhost:8082 or http://localhost:28082." >&2
  echo "Set REFDATA_ADMIN_URL explicitly if needed." >&2
  exit 2
}

url="$(pick_admin_url)"
echo "Re-enabling primary refdata via: $url?value=true"
curl -fsS "$url?value=true"
echo ""
