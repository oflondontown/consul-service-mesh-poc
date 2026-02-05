#!/usr/bin/env sh
set -eu

MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-180}"
WEBSERVICE_URL="${WEBSERVICE_URL:-http://localhost:8080}"
REFDATA_ADMIN_URL="${REFDATA_ADMIN_URL:-}"
CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-http://localhost:8500}"

if ! command -v curl >/dev/null 2>&1; then
  echo "Missing required command: curl" >&2
  exit 2
fi

case "$CONSUL_HTTP_ADDR" in
  http://*|https://*)
    ;;
  *)
    CONSUL_HTTP_ADDR="http://${CONSUL_HTTP_ADDR}"
    ;;
esac

pick_refdata_admin_url() {
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
    echo "  - All-in-one demo: REFDATA_ADMIN_URL=http://localhost:28082/admin/active" >&2
    echo "  - VM-hosted mocks: REFDATA_ADMIN_URL=http://localhost:8082/admin/active" >&2
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

wait_http_ok() {
  url="$1"
  deadline=$(( $(date +%s) + MAX_WAIT_SECONDS ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for HTTP 2xx: $url" >&2
  return 1
}

wait_for_refdata_dc() {
  expected="$1"
  url="${WEBSERVICE_URL}/api/refdata/demo"
  deadline=$(( $(date +%s) + MAX_WAIT_SECONDS ))
  last_body=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    body="$(curl -sS "$url" 2>/dev/null || true)"
    if echo "$body" | grep -q "\"datacenter\":\"$expected\""; then
      echo "$body"
      return 0
    fi
    if [ -n "$body" ]; then
      last_body="$body"
    fi
    sleep 2
  done
  echo "Timed out waiting for refdata datacenter=$expected via $url" >&2
  if [ -n "$last_body" ]; then
    echo "Last response body:" >&2
    echo "$last_body" >&2
  fi
  return 1
}

wait_for_consul_dc() {
  dc="$1"
  deadline=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    dcs="$(curl -sS "${CONSUL_HTTP_ADDR}/v1/catalog/datacenters" 2>/dev/null || true)"
    echo "$dcs" | grep -q "\"${dc}\"" && return 0
    sleep 2
  done
  echo "ERROR: Consul datacenters does not include ${dc}. Got: ${dcs:-<empty>}" >&2
  echo "If you're running only one DC (or the single-VM POC stack), cross-DC failover cannot work." >&2
  echo "For a 1-laptop cross-DC demo, start: ./scripts/start.sh" >&2
  return 1
}

wait_for_passing_service() {
  dc="$1"
  name="$2"
  deadline=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    body="$(curl -sS "${CONSUL_HTTP_ADDR}/v1/health/service/${name}?dc=${dc}&passing=1" 2>/dev/null || true)"
    echo "$body" | grep -q "\"ServiceName\":\"${name}\"" && return 0
    sleep 2
  done
  echo "ERROR: Timed out waiting for passing service '${name}' in ${dc} via Consul HTTP (${CONSUL_HTTP_ADDR})." >&2
  echo "This usually means the mesh gateway is not registered/healthy, so cross-DC traffic cannot flow." >&2
  return 1
}

echo "Waiting for Consul (${CONSUL_HTTP_ADDR})..."
wait_http_ok "${CONSUL_HTTP_ADDR}/v1/status/leader"

echo "Waiting for WAN federation/catalog to include dc2..."
wait_for_consul_dc "dc2"

echo "Waiting for passing mesh gateways (dc1 + dc2)..."
wait_for_passing_service "dc1" "mesh-gateway"
wait_for_passing_service "dc2" "mesh-gateway"

echo "Waiting for webservice..."
wait_http_ok "${WEBSERVICE_URL}/actuator/health"

echo ""
echo "== Baseline (should be dc1 refdata) =="
curl -fsS "${WEBSERVICE_URL}/api/refdata/demo"
echo ""

echo ""
echo "== Order path (webservice -> ordermanager -> refdata) =="
curl -fsS "${WEBSERVICE_URL}/api/orders/123"
echo ""

refdata_admin="$(pick_refdata_admin_url)"
echo ""
echo "Disabling primary refdata (dc1) via ${refdata_admin}..."
curl -fsS "${refdata_admin}?value=false" >/dev/null
echo "Waiting for Consul health hysteresis + failover..."

echo ""
echo "== After failover (should be dc2 refdata) =="
wait_for_refdata_dc "dc2"
echo "OK: webservice is now using dc2 refdata"

echo ""
echo "Re-enabling primary refdata (dc1)..."
curl -fsS "${refdata_admin}?value=true" >/dev/null
echo "Done."
