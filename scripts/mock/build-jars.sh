#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if [[ -x "./gradlew" ]]; then
  GRADLE_CMD="./gradlew"
elif command -v gradle >/dev/null 2>&1; then
  GRADLE_CMD="gradle"
else
  echo "Missing Gradle. Install 'gradle' or add the Gradle wrapper to this repo." >&2
  exit 2
fi

$GRADLE_CMD \
  :services:webservice:bootJar \
  :services:ordermanager:bootJar \
  :services:refdata:jar \
  :services:itch-feed:jar \
  :services:itch-consumer:jar \
  --no-daemon

echo "Built jars under services/*/build/libs/"
