#!/usr/bin/env sh
set -eu

NO_BUILD="${NO_BUILD:-0}"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-auto}"

compose() {
  if [ "$CONTAINER_ENGINE" = "docker" ]; then
    docker compose "$@"
    return
  fi

  if [ "$CONTAINER_ENGINE" = "podman" ]; then
    if command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
      podman compose "$@"
      return
    fi
    if command -v podman-compose >/dev/null 2>&1; then
      podman-compose "$@"
      return
    fi
    echo "Podman is installed but no compose frontend found. Install podman-compose or a podman compose plugin." >&2
    exit 1
  fi

  if command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    podman compose "$@"
    return
  fi
  if command -v podman-compose >/dev/null 2>&1; then
    podman-compose "$@"
    return
  fi
  if command -v docker >/dev/null 2>&1; then
    docker compose "$@"
    return
  fi

  echo "No container engine found. Install Docker or Podman, or set CONTAINER_ENGINE=docker|podman." >&2
  exit 1
}

if [ "$NO_BUILD" = "1" ]; then
  compose up -d
else
  compose up -d --build
fi
