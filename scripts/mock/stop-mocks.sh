#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 --dc dc1|dc2

Stops the host (non-container) mock services started by scripts/mock/start-mocks.sh.
EOF
}

DC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dc)
      DC="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$DC" != "dc1" && "$DC" != "dc2" ]]; then
  echo "Missing/invalid --dc (dc1|dc2)" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_DIR="${RUN_DIR:-$ROOT_DIR/run/mocks/${DC}}"
PID_DIR="${RUN_DIR}/pids"

stop_pidfile() {
  local name="$1"
  local pid_file="$2"

  if [[ ! -f "$pid_file" ]]; then
    return 0
  fi

  pid="$(cat "$pid_file" || true)"
  if [[ -z "$pid" ]]; then
    rm -f "$pid_file"
    return 0
  fi

  echo "Stopping $name (pid $pid)..."
  kill "$pid" >/dev/null 2>&1 || true

  for _ in $(seq 1 20); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      rm -f "$pid_file"
      return 0
    fi
    sleep 1
  done

  echo "Force killing $name (pid $pid)..."
  kill -9 "$pid" >/dev/null 2>&1 || true
  rm -f "$pid_file"
}

stop_pidfile "webservice-${DC}" "$PID_DIR/webservice.pid"
stop_pidfile "ordermanager-${DC}" "$PID_DIR/ordermanager.pid"
stop_pidfile "refdata-${DC}" "$PID_DIR/refdata.pid"
stop_pidfile "itch-feed-${DC}" "$PID_DIR/itch-feed.pid"
stop_pidfile "itch-consumer-${DC}" "$PID_DIR/itch-consumer.pid"

echo "Stopped mocks for ${DC}"

