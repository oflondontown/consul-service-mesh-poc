#!/usr/bin/env sh
set -eu

REFDATA_ADMIN_URL="${REFDATA_ADMIN_URL:-}"

pick_admin_url() {
  if [ -n "$REFDATA_ADMIN_URL" ]; then
    echo "$REFDATA_ADMIN_URL"
    return
  fi

  # Prefer VM-hosted default (8082). If you're running the all-container demo,
  # the refdata primary container is published as 28082.
  if command -v curl >/dev/null 2>&1 && curl -sS "http://localhost:8082/health" >/dev/null 2>&1; then
    echo "http://localhost:8082/admin/active"
    return
  fi
  echo "http://localhost:28082/admin/active"
}

url="$(pick_admin_url)"
echo "Disabling primary refdata via: $url?value=false"
curl -fsS "$url?value=false"
echo ""
