#!/bin/bash
set -euo pipefail

# Run Maestro E2E flows on Android emulator
# Usage: ./run-maestro-android.sh [flow-path]
#
# Prerequisites:
#   - Android emulator running with the app installed (make mobile.e2e.build)
#   - Phoenix server running on port 4200 (make dev)
#   - E2E data seeded (make mobile.e2e.seed)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOBILE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MAESTRO_DIR="$MOBILE_DIR/.maestro"
REPORTS_DIR="$MOBILE_DIR/e2e/reports"

mkdir -p "$REPORTS_DIR"

# ── Pre-flight checks ─────────────────────────────────────────────────

# Java (required by Maestro)
# macOS ships a /usr/bin/java stub that prints an error instead of running,
# so we check that java actually works, not just that it exists on PATH.
if ! java -version &>/dev/null; then
  if [ -d "$HOME/.local/share/mise/installs/java" ]; then
    JAVA_DIR=$(find "$HOME/.local/share/mise/installs/java" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [ -n "$JAVA_DIR" ]; then
      export JAVA_HOME="$JAVA_DIR"
      export PATH="$JAVA_HOME/bin:$PATH"
    fi
  fi
  if ! java -version &>/dev/null; then
    echo "ERROR: Java is required for Maestro. Install via: mise install java@temurin-21"
    exit 1
  fi
fi
export JAVA_HOME="${JAVA_HOME:-$(java -XshowSettings:property -version 2>&1 | grep 'java.home' | awk '{print $3}')}"

if ! command -v maestro &>/dev/null; then
  echo "ERROR: Maestro CLI not found. Install via: brew install mobile-dev-inc/tap/maestro --formula"
  exit 1
fi

if ! lsof -i :4200 &>/dev/null; then
  echo "ERROR: Phoenix server not running on port 4200. Start with: make dev"
  exit 1
fi

# Metro bundler
METRO_PID=""
if ! lsof -i :8081 &>/dev/null; then
  echo "==> Starting Metro bundler..."
  cd "$MOBILE_DIR"
  npx expo start --port 8081 &>/tmp/metro-e2e.log &
  METRO_PID=$!
  for i in $(seq 1 30); do
    if lsof -i :8081 &>/dev/null; then
      echo "    Metro ready (PID $METRO_PID)"
      break
    fi
    [ "$i" -eq 30 ] && echo "ERROR: Metro failed to start." && exit 1
    sleep 1
  done
fi

cleanup() {
  if [ -n "$METRO_PID" ]; then
    echo "==> Stopping Metro bundler (PID $METRO_PID)..."
    kill "$METRO_PID" 2>/dev/null || true
    wait "$METRO_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── E2E env vars ──────────────────────────────────────────────────────

E2E_USER_EMAIL="${E2E_USER_EMAIL:-e2e@loomkin.test}"
E2E_USER_PASSWORD="${E2E_USER_PASSWORD:-e2e-test-password}"
API_BASE_URL="${API_BASE_URL:-http://10.0.2.2:4200}"

# ── Run tests ─────────────────────────────────────────────────────────

if [ -n "${1:-}" ]; then
  FLOW_PATH="$1"
  echo "==> Running Maestro Android E2E: $FLOW_PATH"
  maestro test "$FLOW_PATH" \
    --platform android \
    --env API_BASE_URL="$API_BASE_URL" \
    --env E2E_USER_EMAIL="$E2E_USER_EMAIL" \
    --env E2E_USER_PASSWORD="$E2E_USER_PASSWORD"
  exit $?
fi

echo "==> Running all Maestro Android E2E tests"
echo "    Reports: $REPORTS_DIR"

EXIT_CODE=0
FLOW_DIRS=$(find "$MAESTRO_DIR/flows" -mindepth 1 -maxdepth 1 -type d | sort)

for dir in $FLOW_DIRS; do
  suite=$(basename "$dir")
  echo ""
  echo "── Suite: $suite ──────────────────────────────────────"
  maestro test "$dir" \
    --platform android \
    --format junit \
    --output "$REPORTS_DIR/android-${suite}.xml" \
    --env API_BASE_URL="$API_BASE_URL" \
    --env E2E_USER_EMAIL="$E2E_USER_EMAIL" \
    --env E2E_USER_PASSWORD="$E2E_USER_PASSWORD" || EXIT_CODE=1
done

echo ""
[ "$EXIT_CODE" -eq 0 ] && echo "==> All Android E2E suites passed!" || echo "==> Some Android E2E suites failed. Check reports in $REPORTS_DIR"
exit $EXIT_CODE
