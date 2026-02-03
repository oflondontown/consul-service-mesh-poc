#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vm/scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

CONSUL_BIN="${CONSUL_BIN:-consul}"
CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}"

GATEWAY_SERVICE_NAME="${GATEWAY_SERVICE_NAME:-mesh-gateway}"
GATEWAY_ADDRESS="${GATEWAY_ADDRESS:-}"
GATEWAY_WAN_ADDRESS="${GATEWAY_WAN_ADDRESS:-$GATEWAY_ADDRESS}"
ENVOY_ADMIN_BIND="${ENVOY_ADMIN_BIND:-127.0.0.1:19001}"
EXPOSE_SERVERS="${EXPOSE_SERVERS:-0}"

if [ -z "$GATEWAY_ADDRESS" ]; then
  echo "Missing GATEWAY_ADDRESS (example: 10.0.0.10:8443)" >&2
  exit 2
fi

export CONSUL_HTTP_ADDR

log "Waiting for local Consul agent at $CONSUL_HTTP_ADDR..."
wait_for_consul_agent

args=(connect envoy -gateway=mesh -register -service "$GATEWAY_SERVICE_NAME" -address "$GATEWAY_ADDRESS" -wan-address "$GATEWAY_WAN_ADDRESS" -admin-bind "$ENVOY_ADMIN_BIND")
if [ "$EXPOSE_SERVERS" = "1" ]; then
  args+=( -expose-servers )
fi

log "Starting mesh gateway: service=$GATEWAY_SERVICE_NAME address=$GATEWAY_ADDRESS wan_address=$GATEWAY_WAN_ADDRESS admin=$ENVOY_ADMIN_BIND"

if [ -n "${PID_FILE:-}" ]; then
  mkdirp "$(dirname "$PID_FILE")"
  echo "$$" >"$PID_FILE"
  log "Wrote PID file: $PID_FILE"
fi

exec "$CONSUL_BIN" "${args[@]}" ${ENVOY_EXTRA_ARGS:-}

