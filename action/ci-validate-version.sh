#!/bin/bash
# Validate Docker image version tag

set -e

VERSION="${1:-latest}"

# Validate version format (alphanumeric, dots, hyphens, underscores)
if [[ ! "$VERSION" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "❌ Error: Invalid version format"
    echo "   Provided: ${VERSION}"
    exit 1
fi

# Check length (Docker tags max 128 chars)
if [ ${#VERSION} -gt 128 ]; then
    echo "❌ Error: Version tag too long (max 128 characters)"
    exit 1
fi

echo "Selected version: ${VERSION}"

# Authenticate to GHCR
echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin

# Verify version exists
if docker manifest inspect "ghcr.io/rediacc/elite/api:${VERSION}" > /dev/null 2>&1; then
    echo "✅ Version ${VERSION} verified in registry"
else
    echo "⚠️  Warning: Version ${VERSION} not found in registry (continuing anyway)"
fi

# Logout immediately
docker logout ghcr.io

# Export for subsequent steps
echo "TAG=${VERSION}" >> $GITHUB_ENV
