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

    # Pull all required images using per-image tags
    # WEB_TAG, API_TAG, BRIDGE_TAG are set by console CI workflow
    echo "Pulling web:${WEB_TAG}..."
    docker pull --quiet "${DOCKER_REGISTRY}/web:${WEB_TAG}"

    echo "Pulling api:${API_TAG}..."
    docker pull --quiet "${DOCKER_REGISTRY}/api:${API_TAG}"

    echo "Pulling bridge:${BRIDGE_TAG}..."
    docker pull --quiet "${DOCKER_REGISTRY}/bridge:${BRIDGE_TAG}"

    # Pull Caddy gateway image if desktop is enabled
    if [ "$ENABLE_DESKTOP" == "true" ]; then
        echo "Pulling caddy:alpine for desktop gateway..."
        docker pull --quiet caddy:alpine
    fi

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
