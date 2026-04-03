#!/bin/bash
set -euo pipefail

# Seed the backend with E2E test data
# This creates the e2e test user, sample sessions, teams, and messages

REPO_ROOT="$(git rev-parse --show-toplevel)"
SERVER_DIR="$REPO_ROOT/loomkin-server"

echo "==> Seeding E2E test data"

cd "$SERVER_DIR"
mix run priv/repo/seeds/e2e_seeds.exs

echo "==> E2E test data seeded successfully"
