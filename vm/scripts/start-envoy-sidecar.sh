#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vm/scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_env SERVICE_ID

CONSUL_BIN="${CONSUL_BIN:-consul}"
CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}"
ENVOY_ADMIN_BIND="${ENVOY_ADMIN_BIND:-127.0.0.1:19000}"
FOREGROUND="${FOREGROUND:-0}"
STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-60}"

pid_file="${PID_FILE:-$HOME/run/pids/${SERVICE_ID}.envoy.pid}"
log_file="${ENVOY_LOG_FILE:-$HOME/run/logs/${SERVICE_ID}.envoy.log}"

export CONSUL_HTTP_ADDR

log "Waiting for local Consul agent at $CONSUL_HTTP_ADDR..."
wait_for_consul_agent

log "Waiting for service registration: $SERVICE_ID"
if ! wait_for_http "${CONSUL_HTTP_ADDR%/}/v1/agent/service/$SERVICE_ID" "$STARTUP_TIMEOUT_SECONDS"; then
  echo "Timed out waiting for local agent to register service id: $SERVICE_ID" >&2
  exit 4
fi

log "Starting Envoy sidecar for service id: $SERVICE_ID (admin=$ENVOY_ADMIN_BIND)"

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
  exec "$CONSUL_BIN" connect envoy \
  -sidecar-for "$SERVICE_ID" \
  -admin-bind "$ENVOY_ADMIN_BIND" \
  ${ENVOY_EXTRA_ARGS:-}
fi

log "Starting in background (pidfile=$pid_file log=$log_file)"
start_background_process "$pid_file" "$log_file" "$CONSUL_BIN" connect envoy \
  -sidecar-for "$SERVICE_ID" \
  -admin-bind "$ENVOY_ADMIN_BIND" \
  ${ENVOY_EXTRA_ARGS:-}

log "Waiting for Envoy admin endpoint at $admin_url..."
if ! wait_for_http "$admin_url" "$STARTUP_TIMEOUT_SECONDS"; then
  echo "Envoy did not become ready. Check log: $log_file" >&2
  exit 3
fi

log "Envoy sidecar started (pid=$(cat "$pid_file"))."
