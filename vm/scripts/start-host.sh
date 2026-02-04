#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vm/scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

require_env CONSUL_DATACENTER
require_env CONSUL_NODE_NAME
require_env CONSUL_BIND_ADDR
require_env CONSUL_CLIENT_ADDR
require_env CONSUL_DATA_DIR

CONSUL_MODE="${CONSUL_MODE:-server}"            # server | agent
START_MESH_GATEWAY="${START_MESH_GATEWAY:-1}"  # 1 | 0

PID_DIR="${PID_DIR:-$HOME/run/pids}"
LOG_DIR="${LOG_DIR:-$HOME/run/logs}"
mkdirp "$PID_DIR" "$LOG_DIR"

# Default to the example service defs + sidecar list for this datacenter.
CONSUL_SERVICE_DEFS_DIR="${CONSUL_SERVICE_DEFS_DIR:-$ROOT_DIR/vm/config/services/$CONSUL_DATACENTER}"
SERVICE_SIDECARS_FILE="${SERVICE_SIDECARS_FILE:-$ROOT_DIR/vm/config/nodes/$CONSUL_DATACENTER/sidecars.txt}"

CONSUL_PID_FILE="${CONSUL_PID_FILE:-$PID_DIR/consul-$CONSUL_DATACENTER.pid}"
CONSUL_LOG_FILE="${CONSUL_LOG_FILE:-$LOG_DIR/consul-$CONSUL_DATACENTER.log}"

log "Starting host runtime: dc=$CONSUL_DATACENTER mode=$CONSUL_MODE bind=$CONSUL_BIND_ADDR"

http_host="$CONSUL_CLIENT_ADDR"
if [ "$http_host" = "0.0.0.0" ]; then
  http_host="127.0.0.1"
fi
export CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-http://${http_host}:8500}"

if [ "$CONSUL_MODE" = "server" ]; then
  CONSUL_CONFIG_FILE="${CONSUL_CONFIG_FILE:-$ROOT_DIR/vm/config/consul/server-$CONSUL_DATACENTER.hcl}"
  export CONSUL_CONFIG_FILE

  PID_FILE="$CONSUL_PID_FILE" CONSUL_LOG_FILE="$CONSUL_LOG_FILE" CONSUL_SERVICE_DEFS_DIR="$CONSUL_SERVICE_DEFS_DIR" \
    "$SCRIPT_DIR/start-consul-server.sh"
elif [ "$CONSUL_MODE" = "agent" ]; then
  require_env CONSUL_RETRY_JOIN
  PID_FILE="$CONSUL_PID_FILE" CONSUL_LOG_FILE="$CONSUL_LOG_FILE" CONSUL_SERVICE_DEFS_DIR="$CONSUL_SERVICE_DEFS_DIR" \
    "$SCRIPT_DIR/start-consul-agent.sh"
else
  echo "Unsupported CONSUL_MODE: $CONSUL_MODE (use server|agent)" >&2
  exit 2
fi

if [ "$START_MESH_GATEWAY" = "1" ]; then
  GATEWAY_SERVICE_NAME="${GATEWAY_SERVICE_NAME:-mesh-gateway-$CONSUL_DATACENTER}"
  GATEWAY_ADDRESS="${GATEWAY_ADDRESS:-$CONSUL_BIND_ADDR:8443}"
  GATEWAY_WAN_ADDRESS="${GATEWAY_WAN_ADDRESS:-$GATEWAY_ADDRESS}"
  MESH_GATEWAY_ADMIN_BIND="${MESH_GATEWAY_ADMIN_BIND:-127.0.0.1:29050}"

  export GATEWAY_SERVICE_NAME GATEWAY_ADDRESS GATEWAY_WAN_ADDRESS

  PID_FILE="$PID_DIR/${GATEWAY_SERVICE_NAME}.mesh-gateway.pid" \
    ENVOY_ADMIN_BIND="$MESH_GATEWAY_ADMIN_BIND" ENVOY_LOG_FILE="$LOG_DIR/${GATEWAY_SERVICE_NAME}.mesh-gateway.log" \
    "$SCRIPT_DIR/start-mesh-gateway.sh"
fi

if [ ! -f "$SERVICE_SIDECARS_FILE" ]; then
  echo "SERVICE_SIDECARS_FILE not found: $SERVICE_SIDECARS_FILE" >&2
  exit 2
fi

log "Starting sidecars from: $SERVICE_SIDECARS_FILE"
while IFS= read -r line; do
  # strip leading/trailing whitespace
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -z "$line" ] && continue
  case "$line" in
    \#*) continue ;;
  esac

  set -- $line
  service_id="${1:-}"
  admin_port="${2:-}"
  if [ -z "$service_id" ] || [ -z "$admin_port" ]; then
    echo "Invalid line in SERVICE_SIDECARS_FILE (expected: <service_id> <admin_port>): $line" >&2
    exit 2
  fi

  PID_FILE="$PID_DIR/${service_id}.envoy.pid" ENVOY_LOG_FILE="$LOG_DIR/${service_id}.envoy.log" \
    SERVICE_ID="$service_id" ENVOY_ADMIN_BIND="127.0.0.1:$admin_port" \
    "$SCRIPT_DIR/start-envoy-sidecar.sh"
done <"$SERVICE_SIDECARS_FILE"

log "Host runtime started."
