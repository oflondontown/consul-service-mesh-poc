#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vm/scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_env SERVICE_ID

CONSUL_BIN="${CONSUL_BIN:-consul}"
CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}"
ENVOY_ADMIN_BIND="${ENVOY_ADMIN_BIND:-127.0.0.1:19000}"

export CONSUL_HTTP_ADDR

log "Waiting for local Consul agent at $CONSUL_HTTP_ADDR..."
wait_for_consul_agent

log "Starting Envoy sidecar for service id: $SERVICE_ID (admin=$ENVOY_ADMIN_BIND)"

if [ -n "${PID_FILE:-}" ]; then
  mkdirp "$(dirname "$PID_FILE")"
  echo "$$" >"$PID_FILE"
  log "Wrote PID file: $PID_FILE"
fi

exec "$CONSUL_BIN" connect envoy \
  -sidecar-for "$SERVICE_ID" \
  -admin-bind "$ENVOY_ADMIN_BIND" \
  ${ENVOY_EXTRA_ARGS:-}

