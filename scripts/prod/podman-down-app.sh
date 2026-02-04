#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib-podman.sh
source "${SCRIPT_DIR}/lib-podman.sh"

require_cmd podman

usage() {
  cat <<EOF
Usage: $0 [--env-file <path>]

Loads environment variables from an env file (KEY=VALUE) before stopping containers.
If --env-file is omitted and scripts/prod/app.env exists, it is loaded automatically.
EOF
}

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
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

require_env CONSUL_DATACENTER

DC="${CONSUL_DATACENTER}"
POD="mesh-app-${DC}"

log "Stopping/removing pod: ${POD}"
podman pod rm -f "${POD}" >/dev/null 2>&1 || true

if [[ "${REMOVE_VOLUMES:-0}" == "1" ]]; then
  log "Removing volumes for ${DC}"
  podman volume rm -f "consul-agent-data-${DC}" >/dev/null 2>&1 || true
  podman volume rm -f "webservice-envoy-bootstrap-${DC}" >/dev/null 2>&1 || true
  podman volume rm -f "ordermanager-envoy-bootstrap-${DC}" >/dev/null 2>&1 || true
  podman volume rm -f "refdata-envoy-bootstrap-${DC}" >/dev/null 2>&1 || true
  podman volume rm -f "itch-feed-envoy-bootstrap-${DC}" >/dev/null 2>&1 || true
  podman volume rm -f "itch-consumer-envoy-bootstrap-${DC}" >/dev/null 2>&1 || true
fi

log "Down: ${POD}"
