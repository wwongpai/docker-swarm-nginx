#!/usr/bin/env bash
# Build and push all custom Docker images to Docker Hub.
#
# Usage:
#   ./scripts/build_push.sh                      # defaults: linux/arm64, wwongpai
#   PLATFORM=linux/amd64 ./scripts/build_push.sh
#   PLATFORM=linux/amd64,linux/arm64 ./scripts/build_push.sh   # multi-arch

set -euo pipefail

DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-wwongpai}"
PLATFORM="${PLATFORM:-linux/arm64}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "==> Building for platform: $PLATFORM"
echo "==> Docker Hub namespace : $DOCKERHUB_NAMESPACE"
echo ""

# ── nginx with Datadog tracing module ─────────────────────────────────────────
echo "[1/3] Building nginx-datadog..."
docker buildx build \
  --platform "$PLATFORM" \
  --push \
  -t "${DOCKERHUB_NAMESPACE}/nginx-datadog:latest" \
  "${ROOT_DIR}/nginx"

echo "[1/3] Done: ${DOCKERHUB_NAMESPACE}/nginx-datadog:latest"
echo ""

# ── Spring Boot (Java) app ────────────────────────────────────────────────────
echo "[2/3] Building springboot-nginx-demo..."
docker buildx build \
  --platform "$PLATFORM" \
  --push \
  -t "${DOCKERHUB_NAMESPACE}/springboot-nginx-demo:latest" \
  "${ROOT_DIR}/springboot-app"

echo "[2/3] Done: ${DOCKERHUB_NAMESPACE}/springboot-nginx-demo:latest"
echo ""

# ── Laravel (PHP) app ─────────────────────────────────────────────────────────
echo "[3/3] Building laravel-nginx-demo..."
docker buildx build \
  --platform "$PLATFORM" \
  --push \
  -t "${DOCKERHUB_NAMESPACE}/laravel-nginx-demo:latest" \
  "${ROOT_DIR}/laravel-app"

echo "[3/3] Done: ${DOCKERHUB_NAMESPACE}/laravel-nginx-demo:latest"
echo ""
echo "All images pushed successfully."
