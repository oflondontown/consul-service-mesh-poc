#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vm/scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

# This wrapper starts the two long-lived processes required on a service VM:
# - Consul client agent (registers the service + performs health checks)
# - Envoy sidecar (Connect proxy for upstreams)
#
# It is useful when you want a single command to (re)start the node.
# The underlying start scripts run in the background by default and exit 0/non-zero
# based on whether startup checks succeeded.

require_env CONSUL_DATACENTER
require_env CONSUL_NODE_NAME
require_env CONSUL_BIND_ADDR
require_env CONSUL_CLIENT_ADDR
require_env CONSUL_DATA_DIR
require_env CONSUL_SERVICE_DEF
require_env CONSUL_RETRY_JOIN
require_env SERVICE_ID

http_host="$CONSUL_CLIENT_ADDR"
if [ "$http_host" = "0.0.0.0" ]; then
  http_host="127.0.0.1"
fi
CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-http://${http_host}:8500}"
export CONSUL_HTTP_ADDR

PID_DIR="${PID_DIR:-$HOME/run/pids}"
LOG_DIR="${LOG_DIR:-$HOME/run/logs}"
mkdirp "$PID_DIR" "$LOG_DIR"

CONSUL_AGENT_PID_FILE="${CONSUL_AGENT_PID_FILE:-$PID_DIR/${SERVICE_ID}.consul-agent.pid}"
ENVOY_PID_FILE="${ENVOY_PID_FILE:-$PID_DIR/${SERVICE_ID}.envoy.pid}"
CONSUL_AGENT_LOG_FILE="${CONSUL_AGENT_LOG_FILE:-$LOG_DIR/${SERVICE_ID}.consul-agent.log}"
ENVOY_LOG_FILE="${ENVOY_LOG_FILE:-$LOG_DIR/${SERVICE_ID}.envoy.log}"

log "Starting service node: dc=$CONSUL_DATACENTER node=$CONSUL_NODE_NAME service_id=$SERVICE_ID"
log "Consul HTTP: $CONSUL_HTTP_ADDR"
log "Consul agent pidfile: $CONSUL_AGENT_PID_FILE"
log "Envoy pidfile: $ENVOY_PID_FILE"

PID_FILE="$CONSUL_AGENT_PID_FILE" CONSUL_LOG_FILE="$CONSUL_AGENT_LOG_FILE" "$SCRIPT_DIR/start-consul-agent.sh"
PID_FILE="$ENVOY_PID_FILE" ENVOY_LOG_FILE="$ENVOY_LOG_FILE" "$SCRIPT_DIR/start-envoy-sidecar.sh"

log "Started. Logs:"
log "- Consul agent: $CONSUL_AGENT_LOG_FILE"
log "- Envoy: $ENVOY_LOG_FILE"
