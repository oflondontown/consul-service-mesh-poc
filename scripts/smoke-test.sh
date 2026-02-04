#!/usr/bin/env sh
set -eu

MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-180}"
WEBSERVICE_URL="${WEBSERVICE_URL:-http://localhost:8080}"
REFDATA_ADMIN_URL="${REFDATA_ADMIN_URL:-}"

pick_refdata_admin_url() {
  if [ -n "$REFDATA_ADMIN_URL" ]; then
    echo "$REFDATA_ADMIN_URL"
    return
  fi

  # VM-hosted default (8082) vs all-container demo (28082)
  if curl -sS "http://localhost:8082/health" >/dev/null 2>&1; then
    echo "http://localhost:8082/admin/active"
    return
  fi
  echo "http://localhost:28082/admin/active"
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
  while [ "$(date +%s)" -lt "$deadline" ]; do
    body="$(curl -fsS "$url" 2>/dev/null || true)"
    if echo "$body" | grep -q "\"datacenter\":\"$expected\""; then
      echo "$body"
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for refdata datacenter=$expected via $url" >&2
  return 1
}

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
echo "Disabling primary refdata (dc1)..."
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
