#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=lib-podman.sh
source "${SCRIPT_DIR}/lib-podman.sh"

require_cmd podman

PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "${PYTHON_BIN}" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
  elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
  else
    die "Missing python (need python3 or python)"
  fi
fi

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
ENABLE_ITCH_CONSUMER="${ENABLE_ITCH_CONSUMER:-0}"
ENVOY_ADMIN_PORT_OFFSET="${ENVOY_ADMIN_PORT_OFFSET:-8000}"
ENABLED_SERVICES="${ENABLED_SERVICES:-}"

TEMPLATE_DIR="${CONSUL_SERVICE_TEMPLATES_DIR:-${REPO_ROOT}/docker/consul/services-vmhost/${DC}}"
if [[ -n "${CONSUL_SERVICE_TEMPLATES_DIR:-}" && ! "${TEMPLATE_DIR}" =~ ^[A-Za-z]:[\\/]|^/ ]]; then
  TEMPLATE_DIR="${REPO_ROOT}/${TEMPLATE_DIR}"
fi
[[ -d "${TEMPLATE_DIR}" ]] || die "Missing service template directory: ${TEMPLATE_DIR}"

POD="mesh-app-${DC}"
AGENT_CONTAINER="consul-agent-${DC}"

AGENT_DATA_VOL="consul-agent-data-${DC}"

ensure_volume "${AGENT_DATA_VOL}"

template_info_tsv() {
  local file="$1"
  "${PYTHON_BIN}" - "$file" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

service = data.get("service", data)
name = service.get("name", "")
service_id = service.get("id", "")
connect = service.get("connect", {}) or {}
sidecar = connect.get("sidecar_service", {}) or {}
sidecar_port = sidecar.get("port", "")
proxy = sidecar.get("proxy", {}) or {}
upstreams = proxy.get("upstreams", []) or []
up_ports = []
for u in upstreams:
    try:
        up_ports.append(str(int(u.get("local_bind_port"))))
    except Exception:
        pass

# tab-separated: name, id, sidecar_port, upstream_ports_csv
print(f"{name}\t{service_id}\t{sidecar_port}\t{','.join(up_ports)}")
PY
}

declare -A port_seen=()
pod_ports=()
add_pod_port() {
  local spec="$1"
  if [[ -z "${port_seen["$spec"]:-}" ]]; then
    port_seen["$spec"]=1
    pod_ports+=(-p "${spec}")
  fi
}

services_to_bootstrap=()

add_pod_port "127.0.0.1:8500:8500/tcp"
add_pod_port "127.0.0.1:8502:8502/tcp"
add_pod_port "8301:8301/tcp"
add_pod_port "8301:8301/udp"

declare -A enabled_service=()
if [[ -n "${ENABLED_SERVICES}" ]]; then
  IFS=',' read -r -a enabled_list <<<"${ENABLED_SERVICES}"
  for s in "${enabled_list[@]}"; do
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    [[ -n "${s}" ]] && enabled_service["${s}"]=1
  done
fi

shopt -s nullglob
for f in "${TEMPLATE_DIR}"/*.json; do
  IFS=$'\t' read -r service_name service_id sidecar_port upstream_ports_csv < <(template_info_tsv "${f}")

  if [[ -z "${service_name}" || -z "${service_id}" ]]; then
    die "Failed to parse service name/id from: ${f}"
  fi

  if [[ "${service_name}" == "itch-consumer" && "${ENABLE_ITCH_CONSUMER}" != "1" ]]; then
    continue
  fi

  if [[ -n "${ENABLED_SERVICES}" && -z "${enabled_service["$service_name"]:-}" ]]; then
    continue
  fi

  if [[ -z "${sidecar_port}" ]]; then
    continue
  fi

  [[ -n "${sidecar_port}" ]] || die "Failed to parse sidecar_service.port from: ${f}"

  admin_port="$((sidecar_port + ENVOY_ADMIN_PORT_OFFSET))"
  bootstrap_vol="${service_name}-envoy-bootstrap-${DC}"

  services_to_bootstrap+=("${service_name}|${service_id}|${admin_port}|${bootstrap_vol}")
  ensure_volume "${bootstrap_vol}"

  add_pod_port "${sidecar_port}:${sidecar_port}/tcp"
  add_pod_port "127.0.0.1:${admin_port}:${admin_port}/tcp"

  if [[ -n "${upstream_ports_csv}" ]]; then
    IFS=',' read -r -a up_ports <<<"${upstream_ports_csv}"
    for up_port in "${up_ports[@]}"; do
      [[ -n "${up_port}" ]] || continue
      add_pod_port "127.0.0.1:${up_port}:${up_port}/tcp"
    done
  fi
done
shopt -u nullglob

ensure_pod "${POD}" "${pod_ports[@]}"

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
  -e ENABLE_ITCH_CONSUMER="${ENABLE_ITCH_CONSUMER}" \
  -e ENABLED_SERVICES="${ENABLED_SERVICES}" \
  -v "${REPO_ROOT}/docker/consul/client.hcl:/consul/config/client.hcl:ro" \
  -v "${TEMPLATE_DIR}:/consul/config/templates:ro" \
  -v "${AGENT_DATA_VOL}:/consul/data" \
  "${CONSUL_IMAGE}" sh -ec "
    mkdir -p /consul/config/rendered
    for f in /consul/config/templates/*.json; do
      name=\"\$(basename \"\$f\")\"
      if [ \"\${ENABLE_ITCH_CONSUMER:-0}\" != \"1\" ] && [ \"\$name\" = \"itch-consumer.json\" ]; then
        continue
      fi
      if [ -n \"\${ENABLED_SERVICES:-}\" ]; then
        svc=\"\${name%.json}\"
        if ! echo \",\${ENABLED_SERVICES},\" | grep -q \",\${svc},\"; then
          continue
        fi
      fi
      sed \"s/__HOST_IP__/${HOST_IP}/g\" \"\$f\" >\"/consul/config/rendered/\$name\"
    done

    node=\"\${CONSUL_NODE_NAME:-app-${DC}-\$(echo \"${HOST_IP}\" | tr '.' '-')}\"

    args=\"agent -config-file=/consul/config/client.hcl -data-dir=/consul/data\"
    args=\"\$args -node=\${node} -datacenter=${DC} -client=0.0.0.0\"
    args=\"\$args -config-dir=/consul/config/rendered\"

    bind=\"\${CONSUL_BIND_ADDR:-0.0.0.0}\"
    args=\"\$args -bind=\${bind}\"

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

for entry in "${services_to_bootstrap[@]}"; do
  IFS='|' read -r service_name service_id admin_port bootstrap_vol <<<"${entry}"

  bootstrap_sidecar "${service_id}" "${admin_port}" "${bootstrap_vol}"
  ensure_envoy "${service_name}-envoy-${DC}" "${bootstrap_vol}"
done

log "Up: ${POD} (${AGENT_CONTAINER} + envoys)"
