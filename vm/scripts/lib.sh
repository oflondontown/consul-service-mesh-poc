#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*" >&2
}

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "Missing required env var: $name" >&2
    exit 2
  fi
}

mkdirp() {
  mkdir -p "$@"
}

wait_for_http() {
  local url="$1"
  local seconds="${2:-60}"

  local deadline=$((SECONDS + seconds))
  while [ $SECONDS -lt $deadline ]; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  return 1
}

wait_for_consul_agent() {
  local addr="${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}"
  if ! wait_for_http "${addr%/}/v1/status/leader" 60; then
    echo "Timed out waiting for Consul HTTP API at $addr" >&2
    exit 3
  fi
}

