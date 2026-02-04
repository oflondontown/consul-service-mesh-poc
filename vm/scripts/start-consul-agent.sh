#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vm/scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_env CONSUL_DATACENTER
require_env CONSUL_NODE_NAME
require_env CONSUL_BIND_ADDR
require_env CONSUL_CLIENT_ADDR
require_env CONSUL_DATA_DIR
require_env CONSUL_RETRY_JOIN

CONSUL_BIN="${CONSUL_BIN:-consul}"
FOREGROUND="${FOREGROUND:-0}"
STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-60}"

pid_file="${PID_FILE:-$CONSUL_DATA_DIR/consul-agent.pid}"
log_file="${CONSUL_LOG_FILE:-$CONSUL_DATA_DIR/consul-agent.log}"

CONFIG_DIR="${CONSUL_RUNTIME_CONFIG_DIR:-$CONSUL_DATA_DIR/config}"
mkdirp "$CONSUL_DATA_DIR" "$CONFIG_DIR"

cp "$SCRIPT_DIR/../config/consul/client.hcl" "$CONFIG_DIR/client.hcl"

if [ -n "${CONSUL_SERVICE_DEFS_DIR:-}" ]; then
  if [ ! -d "$CONSUL_SERVICE_DEFS_DIR" ]; then
    echo "CONSUL_SERVICE_DEFS_DIR is not a directory: $CONSUL_SERVICE_DEFS_DIR" >&2
    exit 2
  fi

  shopt -s nullglob
  service_files=("$CONSUL_SERVICE_DEFS_DIR"/*.json)
  shopt -u nullglob

  if [ ${#service_files[@]} -eq 0 ]; then
    echo "No service definition json files found in: $CONSUL_SERVICE_DEFS_DIR" >&2
    exit 2
  fi

  for f in "${service_files[@]}"; do
    cp "$f" "$CONFIG_DIR/$(basename "$f")"
  done
elif [ -n "${CONSUL_SERVICE_DEFS:-}" ]; then
  for f in $CONSUL_SERVICE_DEFS; do
    if [ ! -f "$f" ]; then
      echo "Service definition file not found: $f" >&2
      exit 2
    fi
    cp "$f" "$CONFIG_DIR/$(basename "$f")"
  done
elif [ -n "${CONSUL_SERVICE_DEF:-}" ]; then
  if [ ! -f "$CONSUL_SERVICE_DEF" ]; then
    echo "Service definition file not found: $CONSUL_SERVICE_DEF" >&2
    exit 2
  fi
  cp "$CONSUL_SERVICE_DEF" "$CONFIG_DIR/service.json"
else
  log "No service definitions provided (CONSUL_SERVICE_DEF/CONSUL_SERVICE_DEFS/CONSUL_SERVICE_DEFS_DIR). Agent will start without pre-registered services."
fi

log "Starting Consul agent: dc=$CONSUL_DATACENTER node=$CONSUL_NODE_NAME bind=$CONSUL_BIND_ADDR client=$CONSUL_CLIENT_ADDR"
log "Retry-join: $CONSUL_RETRY_JOIN"

http_host="$CONSUL_CLIENT_ADDR"
if [ "$http_host" = "0.0.0.0" ]; then
  http_host="127.0.0.1"
fi
export CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-http://${http_host}:8500}"

join_args=()
for addr in $CONSUL_RETRY_JOIN; do
  join_args+=("-retry-join=$addr")
done

if [ "$FOREGROUND" = "1" ]; then
  if [ -n "${PID_FILE:-}" ]; then
    mkdirp "$(dirname "$PID_FILE")"
    echo "$$" >"$PID_FILE"
    log "Wrote PID file: $PID_FILE"
  fi
  exec "$CONSUL_BIN" agent \
  -config-dir="$CONFIG_DIR" \
  -datacenter="$CONSUL_DATACENTER" \
  -node="$CONSUL_NODE_NAME" \
  -bind="$CONSUL_BIND_ADDR" \
  -client="$CONSUL_CLIENT_ADDR" \
  -data-dir="$CONSUL_DATA_DIR" \
  "${join_args[@]}" \
  ${CONSUL_EXTRA_ARGS:-}
fi

log "Starting in background (pidfile=$pid_file log=$log_file)"
start_background_process "$pid_file" "$log_file" "$CONSUL_BIN" agent \
  -config-dir="$CONFIG_DIR" \
  -datacenter="$CONSUL_DATACENTER" \
  -node="$CONSUL_NODE_NAME" \
  -bind="$CONSUL_BIND_ADDR" \
  -client="$CONSUL_CLIENT_ADDR" \
  -data-dir="$CONSUL_DATA_DIR" \
  "${join_args[@]}" \
  ${CONSUL_EXTRA_ARGS:-}

log "Waiting for Consul agent HTTP API at $CONSUL_HTTP_ADDR..."
if ! wait_for_http "${CONSUL_HTTP_ADDR%/}/v1/agent/self" "$STARTUP_TIMEOUT_SECONDS"; then
  echo "Consul agent did not become ready. Check log: $log_file" >&2
  exit 3
fi

log "Consul agent started (pid=$(cat "$pid_file"))."
