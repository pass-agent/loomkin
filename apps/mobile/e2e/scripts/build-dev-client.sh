#!/bin/bash
set -euo pipefail

# Build and install Expo dev client on iOS simulator for E2E testing
# Usage: ./build-dev-client.sh [ios|android]

PLATFORM="${1:-ios}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOBILE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "==> Building Expo dev client for E2E testing (platform: $PLATFORM)"

cd "$MOBILE_DIR"

# Kill any existing Metro process to avoid conflicts
if lsof -i :8081 &>/dev/null; then
  echo "    Stopping existing Metro process..."
  kill "$(lsof -t -i :8081)" 2>/dev/null || true
  sleep 2
fi

# Build and install on simulator (native build, no bundler)
npx expo run:$PLATFORM --no-bundler

echo "==> Dev client built and installed for $PLATFORM"
