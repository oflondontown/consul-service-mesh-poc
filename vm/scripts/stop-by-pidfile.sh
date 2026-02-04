#!/usr/bin/env bash
set -euo pipefail

PID_FILE="${1:-}"
if [ -z "$PID_FILE" ]; then
  echo "Usage: $0 <pidfile>" >&2
  exit 2
fi

if [ ! -f "$PID_FILE" ]; then
  echo "PID file not found: $PID_FILE" >&2
  exit 1
fi

pid="$(cat "$PID_FILE")"
if [ -z "$pid" ]; then
  echo "PID file is empty: $PID_FILE" >&2
  exit 1
fi

if ! kill -0 "$pid" 2>/dev/null; then
  echo "Process not running (pid=$pid). Removing stale pidfile: $PID_FILE" >&2
  rm -f "$PID_FILE"
  exit 0
fi

echo "Stopping pid=$pid..." >&2
kill "$pid"

timeout_seconds="${STOP_TIMEOUT_SECONDS:-30}"
deadline=$((SECONDS + timeout_seconds))
while [ $SECONDS -lt $deadline ]; do
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$PID_FILE"
    echo "Stopped (pid=$pid). Removed pidfile: $PID_FILE" >&2
    exit 0
  fi
  sleep 1
done

echo "Process did not stop within ${timeout_seconds}s (pid=$pid). Sending SIGKILL..." >&2
kill -9 "$pid" 2>/dev/null || true
rm -f "$PID_FILE"
echo "Stopped (SIGKILL). Removed pidfile: $PID_FILE" >&2
