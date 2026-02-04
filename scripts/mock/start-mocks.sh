#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 --dc dc1|dc2 [--enable-itch-consumer 0|1]

Starts the mock services as host (non-container) Java processes:
- webservice (Spring Boot)
- ordermanager (Spring Boot)
- refdata (vanilla Java)
- itch-feed (vanilla Java, TCP)
Optionally (dc1 only): itch-consumer (vanilla Java, HTTP + TCP client)

Assumes:
- Consul/Envoy sidecars are already running (containers) on this VM.
- Jars have been built (run: scripts/mock/build-jars.sh).
EOF
}

DC=""
ENABLE_ITCH_CONSUMER="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dc)
      DC="${2:-}"
      shift 2
      ;;
    --enable-itch-consumer)
      ENABLE_ITCH_CONSUMER="${2:-0}"
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

ROLE="secondary"
if [[ "$DC" == "dc1" ]]; then
  ROLE="primary"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_DIR="${RUN_DIR:-$ROOT_DIR/run/mocks/${DC}}"
PID_DIR="${RUN_DIR}/pids"
LOG_DIR="${RUN_DIR}/logs"
mkdir -p "$PID_DIR" "$LOG_DIR"

jar_webservice="${ROOT_DIR}/services/webservice/build/libs/webservice.jar"
jar_ordermanager="${ROOT_DIR}/services/ordermanager/build/libs/ordermanager.jar"
jar_refdata="${ROOT_DIR}/services/refdata/build/libs/refdata.jar"
jar_itch_feed="${ROOT_DIR}/services/itch-feed/build/libs/itch-feed.jar"
jar_itch_consumer="${ROOT_DIR}/services/itch-consumer/build/libs/itch-consumer.jar"

for j in "$jar_webservice" "$jar_ordermanager" "$jar_refdata" "$jar_itch_feed"; do
  [[ -f "$j" ]] || { echo "Missing jar: $j (run scripts/mock/build-jars.sh)" >&2; exit 2; }
done

start_java() {
  local name="$1"
  local pid_file="$2"
  local log_file="$3"
  shift 3

  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" >/dev/null 2>&1; then
    echo "$name already running (pid $(cat "$pid_file"))"
    return 0
  fi

  echo "Starting $name..."
  ( "$@" >"$log_file" 2>&1 & echo $! >"$pid_file" )
  sleep 1
  if ! kill -0 "$(cat "$pid_file")" >/dev/null 2>&1; then
    echo "Failed to start $name (see $log_file)" >&2
    return 1
  fi
}

wait_http_ok() {
  local url="$1"
  local timeout="${2:-60}"
  local deadline=$(( $(date +%s) + timeout ))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for: $url" >&2
  return 1
}

# refdata
start_java "refdata-${DC}" "$PID_DIR/refdata.pid" "$LOG_DIR/refdata.log" \
  env \
  PORT=8082 SERVICE_NAME=refdata SERVICE_ID="refdata-${DC}" DATACENTER="${DC}" INSTANCE_ROLE="${ROLE}" \
  java -jar "$jar_refdata"
wait_http_ok "http://127.0.0.1:8082/health" 60

# ordermanager
start_java "ordermanager-${DC}" "$PID_DIR/ordermanager.pid" "$LOG_DIR/ordermanager.log" \
  env \
  PORT=8081 SERVICE_NAME=ordermanager SERVICE_ID="ordermanager-${DC}" DATACENTER="${DC}" INSTANCE_ROLE="${ROLE}" \
  REFDATA_BASE_URL="http://127.0.0.1:18182" \
  java -jar "$jar_ordermanager"
wait_http_ok "http://127.0.0.1:8081/actuator/health" 90

# webservice
start_java "webservice-${DC}" "$PID_DIR/webservice.pid" "$LOG_DIR/webservice.log" \
  env \
  PORT=8080 SERVICE_NAME=webservice SERVICE_ID="webservice-${DC}" DATACENTER="${DC}" INSTANCE_ROLE="${ROLE}" \
  REFDATA_BASE_URL="http://127.0.0.1:18082" \
  ORDERMANAGER_BASE_URL="http://127.0.0.1:18083" \
  java -jar "$jar_webservice"
wait_http_ok "http://127.0.0.1:8080/actuator/health" 90

# itch-feed (optional demo service)
start_java "itch-feed-${DC}" "$PID_DIR/itch-feed.pid" "$LOG_DIR/itch-feed.log" \
  env \
  PORT=9000 SERVICE_ID="itch-feed-${DC}" DATACENTER="${DC}" INSTANCE_ROLE="${ROLE}" \
  java -jar "$jar_itch_feed"

if [[ "$DC" == "dc1" && "$ENABLE_ITCH_CONSUMER" == "1" ]]; then
  [[ -f "$jar_itch_consumer" ]] || { echo "Missing jar: $jar_itch_consumer (run scripts/mock/build-jars.sh)" >&2; exit 2; }
  start_java "itch-consumer-${DC}" "$PID_DIR/itch-consumer.pid" "$LOG_DIR/itch-consumer.log" \
    env \
    PORT=9100 SERVICE_NAME=itch-consumer SERVICE_ID="itch-consumer-${DC}" DATACENTER="${DC}" INSTANCE_ROLE="${ROLE}" \
    ITCH_HOST=127.0.0.1 ITCH_PORT=19100 \
    java -jar "$jar_itch_consumer"
  wait_http_ok "http://127.0.0.1:9100/health" 60
fi

echo ""
echo "Mocks running (dc=${DC}). Logs: $LOG_DIR"

