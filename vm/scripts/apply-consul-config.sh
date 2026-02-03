#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vm/scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

CONSUL_BIN="${CONSUL_BIN:-consul}"
CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}"

export CONSUL_HTTP_ADDR

log "Waiting for Consul HTTP API at $CONSUL_HTTP_ADDR..."
wait_for_consul_agent

ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_ENTRIES_DIR="${CONFIG_ENTRIES_DIR:-$ROOT_DIR/vm/config/consul/config-entries}"
if [ ! -d "$CONFIG_ENTRIES_DIR" ]; then
  CONFIG_ENTRIES_DIR="$ROOT_DIR/docker/consul/config-entries"
fi

log "Using config entries dir: $CONFIG_ENTRIES_DIR"

log "Writing config entries to dc1..."
"$CONSUL_BIN" config write -datacenter=dc1 "$CONFIG_ENTRIES_DIR/proxy-defaults.hcl"
"$CONSUL_BIN" config write -datacenter=dc1 "$CONFIG_ENTRIES_DIR/service-defaults.hcl"
"$CONSUL_BIN" config write -datacenter=dc1 "$CONFIG_ENTRIES_DIR/intentions.hcl"
"$CONSUL_BIN" config write -datacenter=dc1 "$CONFIG_ENTRIES_DIR/refdata-resolver-dc1.hcl"
"$CONSUL_BIN" config write -datacenter=dc1 "$CONFIG_ENTRIES_DIR/ordermanager-resolver-dc1.hcl"
"$CONSUL_BIN" config write -datacenter=dc1 "$CONFIG_ENTRIES_DIR/itch-feed-resolver-dc1.hcl"

log "Writing config entries to dc2..."
"$CONSUL_BIN" config write -datacenter=dc2 "$CONFIG_ENTRIES_DIR/proxy-defaults.hcl"
"$CONSUL_BIN" config write -datacenter=dc2 "$CONFIG_ENTRIES_DIR/service-defaults.hcl"
"$CONSUL_BIN" config write -datacenter=dc2 "$CONFIG_ENTRIES_DIR/intentions.hcl"
"$CONSUL_BIN" config write -datacenter=dc2 "$CONFIG_ENTRIES_DIR/refdata-resolver-dc2.hcl"
"$CONSUL_BIN" config write -datacenter=dc2 "$CONFIG_ENTRIES_DIR/ordermanager-resolver-dc2.hcl"
"$CONSUL_BIN" config write -datacenter=dc2 "$CONFIG_ENTRIES_DIR/itch-feed-resolver-dc2.hcl"

log "Done."
