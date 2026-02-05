#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vm/scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

require_env CONSUL_DATACENTER

PID_DIR="${PID_DIR:-$HOME/run/pids}"
LOG_DIR="${LOG_DIR:-$HOME/run/logs}"

SERVICE_SIDECARS_FILE="${SERVICE_SIDECARS_FILE:-$ROOT_DIR/vm/config/nodes/$CONSUL_DATACENTER/sidecars.txt}"

STOP_MESH_GATEWAY="${STOP_MESH_GATEWAY:-1}"  # 1 | 0
STOP_CONSUL="${STOP_CONSUL:-1}"              # 1 | 0

log "Stopping host runtime: dc=$CONSUL_DATACENTER"

if [ -f "$SERVICE_SIDECARS_FILE" ]; then
  log "Stopping sidecars from: $SERVICE_SIDECARS_FILE"
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in
      \#*) continue ;;
    esac

    set -- $line
    service_id="${1:-}"
    [ -z "$service_id" ] && continue

    pid_file="$PID_DIR/${service_id}.envoy.pid"
    if [ -f "$pid_file" ]; then
      "$SCRIPT_DIR/stop-by-pidfile.sh" "$pid_file" || true
    fi
  done <"$SERVICE_SIDECARS_FILE"
else
  log "SERVICE_SIDECARS_FILE not found (skipping sidecars): $SERVICE_SIDECARS_FILE"
fi

if [ "$STOP_MESH_GATEWAY" = "1" ]; then
  gateway_service_name="${GATEWAY_SERVICE_NAME:-mesh-gateway}"
  pid_file="$PID_DIR/${gateway_service_name}.mesh-gateway.pid"
  if [ -f "$pid_file" ]; then
    "$SCRIPT_DIR/stop-by-pidfile.sh" "$pid_file" || true
  fi
fi

if [ "$STOP_CONSUL" = "1" ]; then
  pid_file="${CONSUL_PID_FILE:-$PID_DIR/consul-$CONSUL_DATACENTER.pid}"
  if [ -f "$pid_file" ]; then
    "$SCRIPT_DIR/stop-by-pidfile.sh" "$pid_file" || true
  fi
fi

log "Done. Logs remain under: $LOG_DIR"
