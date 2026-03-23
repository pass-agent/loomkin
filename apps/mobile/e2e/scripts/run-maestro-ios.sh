#!/bin/bash
set -euo pipefail

# Run Maestro E2E flows on iOS simulator
# Usage: ./run-maestro-ios.sh [flow-path]
#   flow-path: optional specific flow file (default: all flows)
#
# Prerequisites:
#   - iOS simulator booted with the app installed (make mobile.e2e.build)
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
  # Try mise-managed Java
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

# Maestro
if ! command -v maestro &>/dev/null; then
  echo "ERROR: Maestro CLI not found. Install via: brew install mobile-dev-inc/tap/maestro --formula"
  exit 1
fi

# Phoenix server
if ! lsof -i :4200 &>/dev/null; then
  echo "ERROR: Phoenix server not running on port 4200. Start with: make dev"
  exit 1
fi

# iOS simulator
if ! xcrun simctl list devices booted 2>/dev/null | grep -q "Booted"; then
  echo "ERROR: No iOS simulator booted. Boot one with: xcrun simctl boot <device-id>"
  exit 1
fi

# Disable iOS AutoFill Passwords to prevent "Save Password?" dialog during E2E tests
BOOTED_UDID=$(xcrun simctl list devices booted -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        if d.get('state') == 'Booted':
            print(d['udid']); sys.exit()
")
if [ -n "$BOOTED_UDID" ]; then
  echo "==> Disabling AutoFill Passwords on simulator $BOOTED_UDID"
  xcrun simctl spawn "$BOOTED_UDID" defaults write com.apple.Preferences AutoFillPasswords -bool NO 2>/dev/null || true
fi

# Metro bundler — start if not running
METRO_PID=""
if ! lsof -i :8081 &>/dev/null; then
  echo "==> Starting Metro bundler..."
  cd "$MOBILE_DIR"
  npx expo start --port 8081 &>/tmp/metro-e2e.log &
  METRO_PID=$!
  # Wait for Metro to be ready
  for i in $(seq 1 30); do
    if lsof -i :8081 &>/dev/null; then
      echo "    Metro ready (PID $METRO_PID)"
      break
    fi
    if [ "$i" -eq 30 ]; then
      echo "ERROR: Metro failed to start. Check /tmp/metro-e2e.log"
      exit 1
    fi
    sleep 1
  done
fi

# ── Cleanup handler ───────────────────────────────────────────────────

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
E2E_USER_PASSWORD="${E2E_USER_PASSWORD:-e2e_test_password_123!}"
E2E_REGISTER_EMAIL="${E2E_REGISTER_EMAIL:-e2e-reg-$(date +%s)@loomkin.test}"
API_BASE_URL="${API_BASE_URL:-http://localhost:4200}"

# ── Run tests ─────────────────────────────────────────────────────────

# If a specific flow is provided, run just that one
if [ -n "${1:-}" ]; then
  FLOW_PATH="$1"
  echo "==> Running Maestro iOS E2E: $FLOW_PATH"
  maestro test "$FLOW_PATH" \
    --platform ios \
    --env API_BASE_URL="$API_BASE_URL" \
    --env E2E_USER_EMAIL="$E2E_USER_EMAIL" \
    --env E2E_USER_PASSWORD="$E2E_USER_PASSWORD" \
    --env E2E_REGISTER_EMAIL="$E2E_REGISTER_EMAIL"
  exit $?
fi

# Otherwise run all flow subdirectories
echo "==> Running all Maestro iOS E2E tests"
echo "    Reports: $REPORTS_DIR"

EXIT_CODE=0
FLOW_DIRS=$(find "$MAESTRO_DIR/flows" -mindepth 1 -maxdepth 1 -type d | sort)

for dir in $FLOW_DIRS; do
  suite=$(basename "$dir")
  echo ""
  echo "── Suite: $suite ──────────────────────────────────────"
  maestro test "$dir" \
    --platform ios \
    --format junit \
    --output "$REPORTS_DIR/ios-${suite}.xml" \
    --env API_BASE_URL="$API_BASE_URL" \
    --env E2E_USER_EMAIL="$E2E_USER_EMAIL" \
    --env E2E_USER_PASSWORD="$E2E_USER_PASSWORD" \
    --env E2E_REGISTER_EMAIL="$E2E_REGISTER_EMAIL" || EXIT_CODE=1
done

echo ""
if [ "$EXIT_CODE" -eq 0 ]; then
  echo "==> All iOS E2E suites passed!"
else
  echo "==> Some iOS E2E suites failed. Check reports in $REPORTS_DIR"
fi

exit $EXIT_CODE
