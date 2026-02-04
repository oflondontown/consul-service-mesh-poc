#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=lib-podman.sh
source "${SCRIPT_DIR}/lib-podman.sh"

require_cmd podman

usage() {
  cat <<EOF
Usage: $0 [--env-file <path>]

Loads environment variables from an env file (KEY=VALUE) before starting containers.
If --env-file is omitted and scripts/prod/app.env exists, it is loaded automatically.
EOF
}

DEFAULT_ENV_FILE="${REPO_ROOT}/scripts/prod/app.env"
ENV_FILE="${ENV_FILE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file|-f)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

if [[ -z "${ENV_FILE}" && -f "${DEFAULT_ENV_FILE}" ]]; then
  ENV_FILE="${DEFAULT_ENV_FILE}"
fi

if [[ -n "${ENV_FILE}" && ! -f "${ENV_FILE}" && -f "${REPO_ROOT}/${ENV_FILE}" ]]; then
  ENV_FILE="${REPO_ROOT}/${ENV_FILE}"
fi

load_env_file "${ENV_FILE}"

CONSUL_IMAGE="${CONSUL_IMAGE:-docker.io/hashicorp/consul:1.17}"
ENVOY_IMAGE="${ENVOY_IMAGE:-docker.io/envoyproxy/envoy:v1.29-latest}"

require_env CONSUL_DATACENTER
require_env HOST_IP
require_env CONSUL_RETRY_JOIN

DC="${CONSUL_DATACENTER}"
HOST_IP="${HOST_IP}"

POD="mesh-app-${DC}"
AGENT_CONTAINER="consul-agent-${DC}"

AGENT_DATA_VOL="consul-agent-data-${DC}"
WEB_BOOTSTRAP_VOL="webservice-envoy-bootstrap-${DC}"
OM_BOOTSTRAP_VOL="ordermanager-envoy-bootstrap-${DC}"
REF_BOOTSTRAP_VOL="refdata-envoy-bootstrap-${DC}"
ITCH_FEED_BOOTSTRAP_VOL="itch-feed-envoy-bootstrap-${DC}"
ITCH_CONSUMER_BOOTSTRAP_VOL="itch-consumer-envoy-bootstrap-${DC}"

ensure_volume "${AGENT_DATA_VOL}"
ensure_volume "${WEB_BOOTSTRAP_VOL}"
ensure_volume "${OM_BOOTSTRAP_VOL}"
ensure_volume "${REF_BOOTSTRAP_VOL}"
ensure_volume "${ITCH_FEED_BOOTSTRAP_VOL}"

ENABLE_ITCH_CONSUMER="${ENABLE_ITCH_CONSUMER:-0}"
if [[ "${DC}" == "dc1" && "${ENABLE_ITCH_CONSUMER}" == "1" ]]; then
  ensure_volume "${ITCH_CONSUMER_BOOTSTRAP_VOL}"
fi

ensure_pod "${POD}" \
  -p "127.0.0.1:8500:8500/tcp" \
  -p "127.0.0.1:8502:8502/tcp" \
  -p "8301:8301/tcp" \
  -p "8301:8301/udp" \
  -p "21000:21000/tcp" \
  -p "21001:21001/tcp" \
  -p "21002:21002/tcp" \
  -p "21003:21003/tcp" \
  -p "21004:21004/tcp" \
  -p "127.0.0.1:18082:18082/tcp" \
  -p "127.0.0.1:18083:18083/tcp" \
  -p "127.0.0.1:18182:18182/tcp" \
  -p "127.0.0.1:19100:19100/tcp" \
  -p "127.0.0.1:29000:29000/tcp" \
  -p "127.0.0.1:29001:29001/tcp" \
  -p "127.0.0.1:29002:29002/tcp" \
  -p "127.0.0.1:29003:29003/tcp" \
  -p "127.0.0.1:29004:29004/tcp"

log "Starting Consul agent (${DC})..."
podman container exists "${AGENT_CONTAINER}" >/dev/null 2>&1 && true

podman rm -f "${AGENT_CONTAINER}" >/dev/null 2>&1 || true
podman run -d --name "${AGENT_CONTAINER}" --pod "${POD}" --restart unless-stopped \
  -e CONSUL_DATACENTER="${DC}" \
  -e CONSUL_NODE_NAME="${CONSUL_NODE_NAME:-}" \
  -e HOST_IP="${HOST_IP}" \
  -e CONSUL_RETRY_JOIN="${CONSUL_RETRY_JOIN}" \
  -e CONSUL_ENCRYPT="${CONSUL_ENCRYPT:-}" \
  -e CONSUL_BIND_ADDR="${CONSUL_BIND_ADDR:-}" \
  -e CONSUL_ADVERTISE_ADDR="${CONSUL_ADVERTISE_ADDR:-}" \
  -v "${REPO_ROOT}/docker/consul/client.hcl:/consul/config/client.hcl:ro" \
  -v "${REPO_ROOT}/docker/consul/services-vmhost/${DC}:/consul/config/templates:ro" \
  -v "${AGENT_DATA_VOL}:/consul/data" \
  "${CONSUL_IMAGE}" sh -ec "
    mkdir -p /consul/config/rendered
    for f in /consul/config/templates/*.json; do
      name=\"\$(basename \"\$f\")\"
      sed \"s/__HOST_IP__/${HOST_IP}/g\" \"\$f\" >\"/consul/config/rendered/\$name\"
    done

    node=\"\${CONSUL_NODE_NAME:-app-${DC}-\$(echo \"${HOST_IP}\" | tr '.' '-')}\"

    args=\"agent -config-file=/consul/config/client.hcl -data-dir=/consul/data\"
    args=\"\$args -node=\${node} -datacenter=${DC} -client=0.0.0.0\"
    args=\"\$args -config-dir=/consul/config/rendered\"

    if [ -n \"\${CONSUL_BIND_ADDR:-}\" ]; then args=\"\$args -bind=\${CONSUL_BIND_ADDR}\"; fi

    advertise=\"\${CONSUL_ADVERTISE_ADDR:-${HOST_IP}}\"
    args=\"\$args -advertise=\${advertise}\"

    if [ -n \"\${CONSUL_ENCRYPT:-}\" ]; then args=\"\$args -encrypt=\${CONSUL_ENCRYPT}\"; fi

    for addr in \$(echo \"\${CONSUL_RETRY_JOIN:-}\" | tr ',' ' '); do
      [ -n \"\$addr\" ] && args=\"\$args -retry-join=\$addr\"
    done

    echo \"Starting: consul \$args\"
    exec consul \$args
  " >/dev/null

log "Waiting for Consul agent..."
for _ in $(seq 1 120); do
  if podman exec "${AGENT_CONTAINER}" sh -ec "wget -qO- http://127.0.0.1:8500/v1/agent/self >/dev/null"; then
    break
  fi
  sleep 1
done
podman exec "${AGENT_CONTAINER}" sh -ec "wget -qO- http://127.0.0.1:8500/v1/agent/self >/dev/null"

bootstrap_sidecar() {
  local service_id="$1"
  local admin_port="$2"
  local volume="$3"
  local bootstrap_name="${service_id}-bootstrap"

  log "Generating Envoy bootstrap: ${service_id}"
  podman run --rm --pod "${POD}" \
    -e CONSUL_HTTP_ADDR="http://127.0.0.1:8500" \
    -e CONSUL_GRPC_ADDR="http://127.0.0.1:8502" \
    -e SERVICE_ID="${service_id}" \
    -e ENVOY_ADMIN_BIND="0.0.0.0:${admin_port}" \
    -v "${volume}:/bootstrap" \
    "${CONSUL_IMAGE}" sh -ec "
      for i in \$(seq 1 240); do wget -qO- \"http://127.0.0.1:8500/v1/agent/service/\${SERVICE_ID}\" >/dev/null 2>&1 && break; sleep 1; done
      wget -qO- \"http://127.0.0.1:8500/v1/agent/service/\${SERVICE_ID}\" >/dev/null
      consul connect envoy -sidecar-for \"\${SERVICE_ID}\" -admin-bind \"\${ENVOY_ADMIN_BIND}\" -bootstrap >/bootstrap/bootstrap.json
    " >/dev/null
}

ensure_envoy() {
  local name="$1"
  local volume="$2"
  shift 2

  ensure_container "${name}" \
    --pod "${POD}" \
    --restart unless-stopped \
    -e ENVOY_EXTRA_ARGS="${ENVOY_EXTRA_ARGS:-}" \
    -v "${volume}:/bootstrap:ro" \
    "${ENVOY_IMAGE}" sh -ec '
      test -s /bootstrap/bootstrap.json
      exec envoy -c /bootstrap/bootstrap.json ${ENVOY_EXTRA_ARGS:-}
    '
}

bootstrap_sidecar "webservice-${DC}" 29000 "${WEB_BOOTSTRAP_VOL}"
bootstrap_sidecar "ordermanager-${DC}" 29001 "${OM_BOOTSTRAP_VOL}"
bootstrap_sidecar "refdata-${DC}" 29002 "${REF_BOOTSTRAP_VOL}"
bootstrap_sidecar "itch-feed-${DC}" 29003 "${ITCH_FEED_BOOTSTRAP_VOL}"

ensure_envoy "webservice-envoy-${DC}" "${WEB_BOOTSTRAP_VOL}"
ensure_envoy "ordermanager-envoy-${DC}" "${OM_BOOTSTRAP_VOL}"
ensure_envoy "refdata-envoy-${DC}" "${REF_BOOTSTRAP_VOL}"
ensure_envoy "itch-feed-envoy-${DC}" "${ITCH_FEED_BOOTSTRAP_VOL}"

if [[ "${DC}" == "dc1" && "${ENABLE_ITCH_CONSUMER}" == "1" ]]; then
  log "Enabling itch-consumer envoy (dc1 only)"
  # Note: pod port mappings for 19100/21004/29004 must be present at pod creation time.
  # If you need this, recreate the pod: podman pod rm -f ${POD}
  bootstrap_sidecar "itch-consumer-${DC}" 29004 "${ITCH_CONSUMER_BOOTSTRAP_VOL}"
  ensure_envoy "itch-consumer-envoy-${DC}" "${ITCH_CONSUMER_BOOTSTRAP_VOL}"
fi

log "Up: ${POD} (${AGENT_CONTAINER} + envoys)"
