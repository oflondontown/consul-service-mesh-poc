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

mkdirp "$CONSUL_DATA_DIR"
mkdirp "$(dirname "${CONSUL_LOG_FILE:-$CONSUL_DATA_DIR/consul-server.log}")"

log "Starting Consul server: dc=$CONSUL_DATACENTER node=$CONSUL_NODE_NAME bind=$CONSUL_BIND_ADDR client=$CONSUL_CLIENT_ADDR"
log "Bootstrap expect: $CONSUL_BOOTSTRAP_EXPECT"
log "Data dir: $CONSUL_DATA_DIR"
log "Config: $CONSUL_CONFIG_FILE"

if [ -n "${PID_FILE:-}" ]; then
  mkdirp "$(dirname "$PID_FILE")"
  echo "$$" >"$PID_FILE"
  log "Wrote PID file: $PID_FILE"
fi

exec "$CONSUL_BIN" agent \
  -server \
  -config-file="$CONSUL_CONFIG_FILE" \
  -bootstrap-expect="$CONSUL_BOOTSTRAP_EXPECT" \
  -datacenter="$CONSUL_DATACENTER" \
  -node="$CONSUL_NODE_NAME" \
  -bind="$CONSUL_BIND_ADDR" \
  -client="$CONSUL_CLIENT_ADDR" \
  -data-dir="$CONSUL_DATA_DIR" \
  ${CONSUL_EXTRA_ARGS:-}
