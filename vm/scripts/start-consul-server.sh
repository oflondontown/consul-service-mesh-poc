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
require_env CONSUL_CONFIG_FILE

CONSUL_BIN="${CONSUL_BIN:-consul}"
CONSUL_BOOTSTRAP_EXPECT="${CONSUL_BOOTSTRAP_EXPECT:-1}"
FOREGROUND="${FOREGROUND:-0}"
STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-60}"

pid_file="${PID_FILE:-$CONSUL_DATA_DIR/consul-server.pid}"
log_file="${CONSUL_LOG_FILE:-$CONSUL_DATA_DIR/consul-server.log}"

CONFIG_DIR="${CONSUL_RUNTIME_CONFIG_DIR:-$CONSUL_DATA_DIR/config}"

mkdirp "$CONSUL_DATA_DIR"
mkdirp "$CONFIG_DIR"
mkdirp "$(dirname "$log_file")"

log "Starting Consul server: dc=$CONSUL_DATACENTER node=$CONSUL_NODE_NAME bind=$CONSUL_BIND_ADDR client=$CONSUL_CLIENT_ADDR"
log "Bootstrap expect: $CONSUL_BOOTSTRAP_EXPECT"
log "Data dir: $CONSUL_DATA_DIR"
log "Config: $CONSUL_CONFIG_FILE"

cp "$CONSUL_CONFIG_FILE" "$CONFIG_DIR/server.hcl"

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
fi

http_host="$CONSUL_CLIENT_ADDR"
if [ "$http_host" = "0.0.0.0" ]; then
  http_host="127.0.0.1"
fi
export CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-http://${http_host}:8500}"

if [ "$FOREGROUND" = "1" ]; then
  if [ -n "${PID_FILE:-}" ]; then
    mkdirp "$(dirname "$PID_FILE")"
    echo "$$" >"$PID_FILE"
    log "Wrote PID file: $PID_FILE"
  fi
  exec "$CONSUL_BIN" agent \
  -server \
  -config-dir="$CONFIG_DIR" \
  -bootstrap-expect="$CONSUL_BOOTSTRAP_EXPECT" \
  -datacenter="$CONSUL_DATACENTER" \
  -node="$CONSUL_NODE_NAME" \
  -bind="$CONSUL_BIND_ADDR" \
  -client="$CONSUL_CLIENT_ADDR" \
  -data-dir="$CONSUL_DATA_DIR" \
  ${CONSUL_EXTRA_ARGS:-}
fi

log "Starting in background (pidfile=$pid_file log=$log_file)"
start_background_process "$pid_file" "$log_file" "$CONSUL_BIN" agent \
  -server \
  -config-dir="$CONFIG_DIR" \
  -bootstrap-expect="$CONSUL_BOOTSTRAP_EXPECT" \
  -datacenter="$CONSUL_DATACENTER" \
  -node="$CONSUL_NODE_NAME" \
  -bind="$CONSUL_BIND_ADDR" \
  -client="$CONSUL_CLIENT_ADDR" \
  -data-dir="$CONSUL_DATA_DIR" \
  ${CONSUL_EXTRA_ARGS:-}

log "Waiting for Consul server HTTP API at $CONSUL_HTTP_ADDR..."
if ! wait_for_http "${CONSUL_HTTP_ADDR%/}/v1/status/leader" "$STARTUP_TIMEOUT_SECONDS"; then
  echo "Consul server did not become ready. Check log: $log_file" >&2
  exit 3
fi

log "Consul server started (pid=$(cat "$pid_file"))."
