#!/bin/bash
# Pre-pull Docker images for CI

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔐 Pre-pulling Docker images with temporary authentication..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Use subshell to contain credential exposure
(
    # Source configuration to get registry and image names
    source "$SCRIPT_DIR/ci-env.sh"
    source "$ELITE_DIR/.env" 2>/dev/null || true

    # Authenticate to registry
    echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin

    # Pull all required images
    echo "Pulling web:${TAG}..."
    docker pull --quiet "${DOCKER_REGISTRY}/web:${TAG}"

    echo "Pulling api:${TAG}..."
    docker pull --quiet "${DOCKER_REGISTRY}/api:${TAG}"

    echo "Pulling bridge image..."
    docker pull --quiet "${DOCKER_BRIDGE_IMAGE}"

    echo "✅ All images pulled successfully"
)

# Cleanup credentials (outside subshell)
echo ""
echo "🧹 Removing all Docker credentials..."
docker logout ghcr.io
rm -f ~/.docker/config.json

# Clear cached credentials
unset GITHUB_TOKEN
unset DOCKER_REGISTRY_PASSWORD

echo "✅ Credentials cleaned - environment is now safe for debug access"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
