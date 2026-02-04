#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*" >&2
}

pid_is_running() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

start_background_process() {
  local pid_file="$1"
  local log_file="$2"
  shift 2

  mkdirp "$(dirname "$pid_file")" "$(dirname "$log_file")"

  if [ -f "$pid_file" ]; then
    local existing_pid
    existing_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if pid_is_running "$existing_pid"; then
      log "Already running (pid=$existing_pid). pidfile=$pid_file"
      return 0
    fi

    log "Removing stale pidfile: $pid_file"
    rm -f "$pid_file"
  fi

  nohup "$@" >>"$log_file" 2>&1 &
  local pid="$!"
  echo "$pid" >"$pid_file"

  # Quick liveness check (catches immediate config/port errors).
  sleep 0.2
  if ! pid_is_running "$pid"; then
    echo "Process exited during startup (pid=$pid). Check log: $log_file" >&2
    return 1
  fi

  return 0
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
