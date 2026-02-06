#!/usr/bin/env sh
# ARCHIVED: deprecated Compose wrapper (see GETTING_STARTED.md).
set -eu

compose() {
  if ! command -v podman >/dev/null 2>&1; then
    echo "podman command not found. Install Podman or Podman Desktop." >&2
    exit 1
  fi

  if podman compose version >/dev/null 2>&1; then
    podman compose "$@"
    return
  fi

  if command -v podman-compose >/dev/null 2>&1; then
    podman-compose "$@"
    return
  fi

  echo "Podman Compose frontend not found. Install podman-compose (or a podman compose plugin)." >&2
  exit 1
}

compose ps
