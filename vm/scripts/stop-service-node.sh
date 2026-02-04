#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vm/scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_env SERVICE_ID

PID_DIR="${PID_DIR:-$HOME/run/pids}"
CONSUL_AGENT_PID_FILE="${CONSUL_AGENT_PID_FILE:-$PID_DIR/${SERVICE_ID}.consul-agent.pid}"
ENVOY_PID_FILE="${ENVOY_PID_FILE:-$PID_DIR/${SERVICE_ID}.envoy.pid}"

log "Stopping service node: $SERVICE_ID"
log "Envoy pidfile: $ENVOY_PID_FILE"
log "Consul agent pidfile: $CONSUL_AGENT_PID_FILE"

# Stop proxy first (so it doesn't keep retrying while the agent is down).
if [ -f "$ENVOY_PID_FILE" ]; then
  "$SCRIPT_DIR/stop-by-pidfile.sh" "$ENVOY_PID_FILE" || true
fi

if [ -f "$CONSUL_AGENT_PID_FILE" ]; then
  "$SCRIPT_DIR/stop-by-pidfile.sh" "$CONSUL_AGENT_PID_FILE" || true
fi

log "Done."

