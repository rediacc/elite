#!/bin/bash
# Universal base image detector for Docker containers
# Detects base images by reading Docker labels from registry API

set -e

# Parse arguments
QUIET=false
CUSTOM_IMAGE=""
REGISTRY_USERNAME=""
REGISTRY_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --quiet|-q)
            QUIET=true
            shift
            ;;
        --username)
            REGISTRY_USERNAME="$2"
            shift 2
            ;;
        --password)
            REGISTRY_PASSWORD="$2"
            shift 2
            ;;
        *)
            CUSTOM_IMAGE="$1"
            shift
            ;;
    esac
done

# Validate input
if [ -z "$CUSTOM_IMAGE" ]; then
    echo "Error: Image name required" >&2
    echo "Usage: $0 [--quiet] <image>" >&2
    exit 1
fi

# Colors for output (disabled in quiet mode)
if [ "$QUIET" = true ]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
fi

[ "$QUIET" = false ] && echo -e "${BLUE}=== Base Image Detector ===${NC}\n"

# Function to get image manifest from registry
get_manifest() {
    local registry="$1"
    local repo="$2"
    local tag="$3"

    local url="https://${registry}/v2/${repo}/manifests/${tag}"

    # Build curl command with optional authentication
    local curl_cmd="curl -sL"
    if [ -n "$REGISTRY_USERNAME" ] && [ -n "$REGISTRY_PASSWORD" ]; then
        curl_cmd="$curl_cmd -u ${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}"
    fi

    # Try to get manifest with standard headers
    $curl_cmd \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
        -H "Accept: application/vnd.oci.image.manifest.v1+json" \
        "$url" 2>/dev/null || echo "{}"
}

# Check if image exists locally first
[ "$QUIET" = false ] && echo -e "${YELLOW}Checking local images...${NC}"

if docker image inspect "$CUSTOM_IMAGE" >/dev/null 2>&1; then
    [ "$QUIET" = false ] && echo -e "${GREEN}✓ Found locally${NC}\n"

    # Check for base image label
    BASE_IMAGE_LABEL=$(docker image inspect "$CUSTOM_IMAGE" --format '{{index .Config.Labels "com.rediacc.base-image"}}' 2>/dev/null)

    if [ -n "$BASE_IMAGE_LABEL" ]; then
        if [ "$QUIET" = true ]; then
            echo "${BASE_IMAGE_LABEL}"
        else
            echo -e "${GREEN}=== DETECTED ===${NC}"
            echo -e "${GREEN}Base image:${NC} ${BLUE}${BASE_IMAGE_LABEL}${NC}"
        fi
        exit 0
    else
        [ "$QUIET" = false ] && echo -e "${YELLOW}No label found in local image${NC}"
    fi
fi

# Parse image into components for registry query
[ "$QUIET" = false ] && echo -e "${YELLOW}Querying registry...${NC}"

# Parse image: [registry/]repository:tag
REGISTRY=$(echo "$CUSTOM_IMAGE" | cut -d'/' -f1)
REMAINDER=$(echo "$CUSTOM_IMAGE" | cut -d'/' -f2-)

# Check if first part is a registry (contains . or :)
if [[ "$REGISTRY" == *"."* ]] || [[ "$REGISTRY" == *":"* ]]; then
    # Has explicit registry
    REPO=$(echo "$REMAINDER" | cut -d':' -f1)
    TAG=$(echo "$REMAINDER" | cut -d':' -f2)
    [ "$TAG" = "$REMAINDER" ] && TAG="latest"
else
    # No explicit registry, use Docker Hub
    REGISTRY="registry-1.docker.io"
    if [[ "$CUSTOM_IMAGE" == *"/"* ]]; then
        REPO=$(echo "$CUSTOM_IMAGE" | cut -d':' -f1)
    else
        # Official image (e.g., nginx:alpine)
        REPO="library/$(echo "$CUSTOM_IMAGE" | cut -d':' -f1)"
    fi
    TAG=$(echo "$CUSTOM_IMAGE" | cut -d':' -f2)
    [ "$TAG" = "$CUSTOM_IMAGE" ] && TAG="latest"
fi

[ "$QUIET" = false ] && echo -e "  Registry: ${REGISTRY}"
[ "$QUIET" = false ] && echo -e "  Repository: ${REPO}"
[ "$QUIET" = false ] && echo -e "  Tag: ${TAG}\n"

# Get manifest
MANIFEST=$(get_manifest "$REGISTRY" "$REPO" "$TAG")

if [ "$MANIFEST" = "{}" ]; then
    [ "$QUIET" = false ] && echo -e "${RED}Failed to get manifest from registry${NC}"
    exit 1
fi

# Get config blob digest
CONFIG_DIGEST=$(echo "$MANIFEST" | jq -r '.config.digest // empty' 2>/dev/null)

if [ -z "$CONFIG_DIGEST" ]; then
    [ "$QUIET" = false ] && echo -e "${RED}No config digest in manifest${NC}"
    exit 1
fi

# Fetch config blob
[ "$QUIET" = false ] && echo -e "${YELLOW}Fetching image config...${NC}"

# Build curl command with optional authentication
BLOB_CURL_CMD="curl -sL"
if [ -n "$REGISTRY_USERNAME" ] && [ -n "$REGISTRY_PASSWORD" ]; then
    BLOB_CURL_CMD="$BLOB_CURL_CMD -u ${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}"
fi

CONFIG_BLOB=$($BLOB_CURL_CMD "https://${REGISTRY}/v2/${REPO}/blobs/${CONFIG_DIGEST}" 2>/dev/null)

# Extract base image label
BASE_IMAGE_LABEL=$(echo "$CONFIG_BLOB" | jq -r '.config.Labels."com.rediacc.base-image" // empty' 2>/dev/null)

if [ -n "$BASE_IMAGE_LABEL" ]; then
    if [ "$QUIET" = true ]; then
        echo "${BASE_IMAGE_LABEL}"
    else
        echo -e "${GREEN}=== DETECTED ===${NC}"
        echo -e "${GREEN}Base image:${NC} ${BLUE}${BASE_IMAGE_LABEL}${NC}"
    fi
    exit 0
else
    [ "$QUIET" = false ] && echo -e "${RED}No base image label found${NC}"
    exit 1
fi
