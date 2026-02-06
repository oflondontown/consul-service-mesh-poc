#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    die "Missing required env var: $name"
  fi
}

load_env_file() {
  local file="$1"

  [[ -n "$file" ]] || return 0
  [[ -f "$file" ]] || die "Env file not found: $file"

  log "Loading env file: $file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"

    # Trim leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "$line" ]] && continue
    [[ "${line:0:1}" == "#" ]] && continue

    if [[ "$line" == export* ]]; then
      line="${line#export }"
      line="${line#"${line%%[![:space:]]*}"}"
    fi

    [[ "$line" == *"="* ]] || die "Invalid line in env file ($file): $line"

    local key="${line%%=*}"
    local value="${line#*=}"

    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"

    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      die "Invalid env var name in env file ($file): $key"
    fi

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ "$value" =~ ^\".*\"$ ]]; then
      value="${value:1:${#value}-2}"
      value="${value//\\\"/\"}"
      value="${value//\\\\/\\}"
    elif [[ "$value" =~ ^\'.*\'$ ]]; then
      value="${value:1:${#value}-2}"
    fi

    export "${key}=${value}"
  done <"$file"
}

ensure_volume() {
  local name="$1"
  if ! podman volume exists "$name" >/dev/null 2>&1; then
    log "Creating volume: $name"
    podman volume create "$name" >/dev/null
  fi
}

ensure_pod() {
  local name="$1"
  shift
  if ! podman pod exists "$name" >/dev/null 2>&1; then
    log "Creating pod: $name"
    podman pod create --name "$name" "$@" >/dev/null
  fi
}

ensure_container() {
  local name="$1"
  shift
  if ! podman container exists "$name" >/dev/null 2>&1; then
    log "Creating container: $name"
    podman run -d --name "$name" "$@" >/dev/null
    return
  fi

  if ! podman container inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q '^true$'; then
    log "Starting existing container: $name"
    podman start "$name" >/dev/null
  fi
}

wait_for_consul_leader() {
  local consul_container="$1"
  local timeout_seconds="${2:-120}"

  log "Waiting for Consul leader on $consul_container (timeout ${timeout_seconds}s)..."
  for _ in $(seq 1 "$timeout_seconds"); do
    if podman exec "$consul_container" sh -ec "wget -qO- http://127.0.0.1:8500/v1/status/leader | grep -q '8300'"; then
      return 0
    fi
    sleep 1
  done

  podman logs --tail 100 "$consul_container" || true
  die "Timed out waiting for Consul leader on $consul_container"
}
