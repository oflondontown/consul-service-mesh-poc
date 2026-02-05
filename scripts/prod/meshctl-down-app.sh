#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

usage() {
  cat <<EOF
Usage: $0 --bundle <path>

Expands a per-host bundle JSON into runtime files under run/mesh/expanded/ and
stops the app stack by calling scripts/prod/podman-down-app.sh.
EOF
}

BUNDLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle|-b)
      BUNDLE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "${BUNDLE}" ]] || { usage >&2; exit 2; }

PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "${PYTHON_BIN}" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
  elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
  else
    echo "Missing python (need python3 or python)" >&2
    exit 2
  fi
fi

exec "${PYTHON_BIN}" "${REPO_ROOT}/tools/meshctl.py" down-app --bundle "${BUNDLE}"

