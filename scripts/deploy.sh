#!/usr/bin/env bash
# Deploy the Docker Swarm stack.
#
# Usage:
#   ./scripts/deploy.sh              # stack name defaults to "nginx-demo"
#   ./scripts/deploy.sh my-stack
#
# The script reads DD_API_KEY from:
#   1. The DD_API_KEY environment variable (if already exported)
#   2. A .env file in the repo root (gitignored, copy from .env.example)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
STACK_NAME="${1:-nginx-demo}"

# ── Load .env if DD_API_KEY is not already in the environment ─────────────────
if [ -z "${DD_API_KEY:-}" ]; then
  if [ -f "${ROOT_DIR}/.env" ]; then
    echo "Loading DD_API_KEY from .env..."
    set -o allexport
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/.env"
    set +o allexport
  fi
fi

if [ -z "${DD_API_KEY:-}" ]; then
  echo "ERROR: DD_API_KEY is not set."
  echo "  Option 1: export DD_API_KEY=<your_key>"
  echo "  Option 2: copy .env.example to .env and fill in DD_API_KEY"
  exit 1
fi

echo "==> Deploying stack '$STACK_NAME'..."
docker stack deploy -c "${ROOT_DIR}/docker-stack.yml" "$STACK_NAME"

echo ""
echo "==> Services:"
docker stack services "$STACK_NAME"

echo ""
echo "==> Access points (replace <host> with your Swarm manager IP):"
echo "    http://<host>/java/      → Spring Boot root"
echo "    http://<host>/java/work  → Spring Boot work (100ms latency)"
echo "    http://<host>/php/       → Laravel root"
echo "    http://<host>/php/work   → Laravel work (100ms latency)"
echo "    http://<host>/health     → nginx health probe"
