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
require_env CONSUL_SERVICE_DEF
require_env CONSUL_RETRY_JOIN

CONSUL_BIN="${CONSUL_BIN:-consul}"

CONFIG_DIR="${CONSUL_RUNTIME_CONFIG_DIR:-$CONSUL_DATA_DIR/config}"
mkdirp "$CONSUL_DATA_DIR" "$CONFIG_DIR"

cp "$SCRIPT_DIR/../config/consul/client.hcl" "$CONFIG_DIR/client.hcl"
cp "$CONSUL_SERVICE_DEF" "$CONFIG_DIR/service.json"

log "Starting Consul agent: dc=$CONSUL_DATACENTER node=$CONSUL_NODE_NAME bind=$CONSUL_BIND_ADDR client=$CONSUL_CLIENT_ADDR"
log "Service def: $CONSUL_SERVICE_DEF"
log "Retry-join: $CONSUL_RETRY_JOIN"

if [ -n "${PID_FILE:-}" ]; then
  mkdirp "$(dirname "$PID_FILE")"
  echo "$$" >"$PID_FILE"
  log "Wrote PID file: $PID_FILE"
fi

join_args=()
for addr in $CONSUL_RETRY_JOIN; do
  join_args+=("-retry-join=$addr")
done

exec "$CONSUL_BIN" agent \
  -config-file="$CONFIG_DIR/client.hcl" \
  -config-file="$CONFIG_DIR/service.json" \
  -datacenter="$CONSUL_DATACENTER" \
  -node="$CONSUL_NODE_NAME" \
  -bind="$CONSUL_BIND_ADDR" \
  -client="$CONSUL_CLIENT_ADDR" \
  -data-dir="$CONSUL_DATA_DIR" \
  "${join_args[@]}" \
  ${CONSUL_EXTRA_ARGS:-}
