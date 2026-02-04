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
FOREGROUND="${FOREGROUND:-0}"
STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-60}"

pid_file="${PID_FILE:-$HOME/run/pids/${GATEWAY_SERVICE_NAME}.mesh-gateway.pid}"
log_file="${ENVOY_LOG_FILE:-$HOME/run/logs/${GATEWAY_SERVICE_NAME}.mesh-gateway.log}"

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

admin_host="${ENVOY_ADMIN_BIND%:*}"
admin_port="${ENVOY_ADMIN_BIND##*:}"
if [ "$admin_host" = "0.0.0.0" ]; then
  admin_host="127.0.0.1"
fi
admin_url="http://${admin_host}:${admin_port}/server_info"

if [ "$FOREGROUND" = "1" ]; then
  if [ -n "${PID_FILE:-}" ]; then
    mkdirp "$(dirname "$PID_FILE")"
    echo "$$" >"$PID_FILE"
    log "Wrote PID file: $PID_FILE"
  fi
  exec "$CONSUL_BIN" "${args[@]}" ${ENVOY_EXTRA_ARGS:-}
fi

log "Starting in background (pidfile=$pid_file log=$log_file)"
start_background_process "$pid_file" "$log_file" "$CONSUL_BIN" "${args[@]}" ${ENVOY_EXTRA_ARGS:-}

log "Waiting for Envoy admin endpoint at $admin_url..."
if ! wait_for_http "$admin_url" "$STARTUP_TIMEOUT_SECONDS"; then
  echo "Mesh gateway did not become ready. Check log: $log_file" >&2
  exit 3
fi

log "Mesh gateway started (pid=$(cat "$pid_file"))."
