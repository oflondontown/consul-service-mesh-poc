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
If --env-file is omitted and scripts/prod/server.env exists, it is loaded automatically.
EOF
}

DEFAULT_ENV_FILE="${REPO_ROOT}/scripts/prod/server.env"
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

DC="${CONSUL_DATACENTER}"
HOST_IP="${HOST_IP}"

POD="mesh-server-${DC}"
CONSUL_CONTAINER="consul-server-${DC}"
GW_CONTAINER="mesh-gateway-${DC}"

CONSUL_DATA_VOL="consul-server-data-${DC}"
GW_BOOTSTRAP_VOL="mesh-gateway-bootstrap-${DC}"

ensure_volume "${CONSUL_DATA_VOL}"
ensure_volume "${GW_BOOTSTRAP_VOL}"

ensure_pod "${POD}" \
  -p "127.0.0.1:8500:8500/tcp" \
  -p "127.0.0.1:8502:8502/tcp" \
  -p "8300:8300/tcp" \
  -p "8301:8301/tcp" \
  -p "8301:8301/udp" \
  -p "8302:8302/tcp" \
  -p "8302:8302/udp" \
  -p "8443:8443/tcp" \
  -p "127.0.0.1:29100:29100/tcp"

bootstrap_expect="${CONSUL_BOOTSTRAP_EXPECT:-3}"
node="${CONSUL_NODE_NAME:-consul-server-${DC}-$(echo "${HOST_IP}" | tr '.' '-')}"
advertise="${CONSUL_ADVERTISE_ADDR:-${HOST_IP}}"
advertise_wan="${CONSUL_ADVERTISE_WAN_ADDR:-${HOST_IP}}"

consul_args=(
  agent
  -config-file=/consul/config/client.hcl
  -data-dir=/consul/data
  -server
  "-bootstrap-expect=${bootstrap_expect}"
  "-node=${node}"
  "-datacenter=${DC}"
  -client=0.0.0.0
  "-advertise=${advertise}"
  "-advertise-wan=${advertise_wan}"
)

if [[ "${CONSUL_ENABLE_UI:-0}" == "1" ]]; then
  consul_args+=(-ui)
fi
if [[ -n "${CONSUL_BIND_ADDR:-}" ]]; then
  consul_args+=("-bind=${CONSUL_BIND_ADDR}")
fi
if [[ -n "${CONSUL_ENCRYPT:-}" ]]; then
  consul_args+=("-encrypt=${CONSUL_ENCRYPT}")
fi

IFS=',' read -r -a lan_peers <<<"${CONSUL_RETRY_JOIN:-}"
for addr in "${lan_peers[@]}"; do
  [[ -n "${addr}" ]] && consul_args+=("-retry-join=${addr}")
done

IFS=',' read -r -a wan_peers <<<"${CONSUL_RETRY_JOIN_WAN:-}"
for addr in "${wan_peers[@]}"; do
  [[ -n "${addr}" ]] && consul_args+=("-retry-join-wan=${addr}")
done

ensure_container "${CONSUL_CONTAINER}" \
  --pod "${POD}" \
  --restart unless-stopped \
  -v "${REPO_ROOT}/docker/consul/client.hcl:/consul/config/client.hcl:ro" \
  -v "${CONSUL_DATA_VOL}:/consul/data" \
  "${CONSUL_IMAGE}" \
  "${consul_args[@]}"

wait_for_consul_leader "${CONSUL_CONTAINER}" 180

log "Applying Consul config entries for ${DC}..."
podman run --rm --pod "${POD}" \
  -e CONSUL_HTTP_ADDR="http://127.0.0.1:8500" \
  -v "${REPO_ROOT}/docker/consul/config-entries:/config-entries:ro" \
  "${CONSUL_IMAGE}" sh -ec "
    consul config write -datacenter='${DC}' /config-entries/proxy-defaults.hcl
    consul config write -datacenter='${DC}' /config-entries/service-defaults.hcl
    consul config write -datacenter='${DC}' /config-entries/intentions.hcl
    consul config write -datacenter='${DC}' \"/config-entries/refdata-resolver-${DC}.hcl\"
    consul config write -datacenter='${DC}' \"/config-entries/ordermanager-resolver-${DC}.hcl\"
    consul config write -datacenter='${DC}' \"/config-entries/itch-feed-resolver-${DC}.hcl\"
  "

MESH_GATEWAY_ADDRESS="${MESH_GATEWAY_ADDRESS:-${HOST_IP}:8443}"
MESH_GATEWAY_WAN_ADDRESS="${MESH_GATEWAY_WAN_ADDRESS:-${MESH_GATEWAY_ADDRESS}}"
EXPOSE_SERVERS="${EXPOSE_SERVERS:-0}"

log "Generating mesh-gateway bootstrap for ${DC}..."
podman run --rm --pod "${POD}" \
  -e CONSUL_HTTP_ADDR="http://127.0.0.1:8500" \
  -e CONSUL_GRPC_ADDR="http://127.0.0.1:8502" \
  -e CONSUL_DATACENTER="${DC}" \
  -e ENVOY_ADMIN_BIND="0.0.0.0:29100" \
  -e MESH_GATEWAY_ADDRESS="${MESH_GATEWAY_ADDRESS}" \
  -e MESH_GATEWAY_WAN_ADDRESS="${MESH_GATEWAY_WAN_ADDRESS}" \
  -e EXPOSE_SERVERS="${EXPOSE_SERVERS}" \
  -v "${GW_BOOTSTRAP_VOL}:/bootstrap" \
  "${CONSUL_IMAGE}" sh -ec "
    args=(connect envoy -gateway=mesh -register -service \"mesh-gateway-${DC}\" -address \"${MESH_GATEWAY_ADDRESS}\" -wan-address \"${MESH_GATEWAY_WAN_ADDRESS}\" -admin-bind \"0.0.0.0:29100\" -bootstrap)
    if [ \"${EXPOSE_SERVERS}\" = \"1\" ]; then args+=( -expose-servers ); fi
    consul \"\${args[@]}\" >/bootstrap/bootstrap.json
  "

ensure_container "${GW_CONTAINER}" \
  --pod "${POD}" \
  --restart unless-stopped \
  -e ENVOY_EXTRA_ARGS="${ENVOY_EXTRA_ARGS:-}" \
  -v "${GW_BOOTSTRAP_VOL}:/bootstrap:ro" \
  "${ENVOY_IMAGE}" sh -ec '
    test -s /bootstrap/bootstrap.json
    exec envoy -c /bootstrap/bootstrap.json ${ENVOY_EXTRA_ARGS:-}
  '

log "Up: ${POD} (${CONSUL_CONTAINER}, ${GW_CONTAINER})"
