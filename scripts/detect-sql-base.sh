#!/bin/bash
# Detect SQL Server base image by layer comparison
# This uses Docker Registry API v2 to inspect images without downloading

set -e

# Parse arguments
QUIET=false
CUSTOM_IMAGE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --quiet|-q)
            QUIET=true
            shift
            ;;
        *)
            CUSTOM_IMAGE="$1"
            shift
            ;;
    esac
done

# Default image if not specified
CUSTOM_IMAGE="${CUSTOM_IMAGE:-registry.rediacc.com/rediacc/sql-server:latest}"

# Configuration
MCR_REGISTRY="mcr.microsoft.com"
MCR_REPO="mssql/server"

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

[ "$QUIET" = false ] && echo -e "${BLUE}=== SQL Server Base Image Detector ===${NC}\n"

# Function to get authentication token for a registry
get_auth_token() {
    local registry="$1"
    local repo="$2"

    if [[ "$registry" == "mcr.microsoft.com" ]]; then
        # MCR uses anonymous access with bearer token
        local auth_url="https://mcr.microsoft.com/v2/"
        curl -sI "$auth_url" | grep -i "www-authenticate" | sed 's/.*realm="\([^"]*\)".*/\1/' || echo ""
    else
        # For private registries, might need credentials
        echo ""
    fi
}

# Function to get image manifest (includes layers)
get_manifest() {
    local registry="$1"
    local repo="$2"
    local tag="$3"

    local url="https://${registry}/v2/${repo}/manifests/${tag}"

    # Try to get manifest, accepting both schema v2 and OCI formats
    curl -sL \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
        -H "Accept: application/vnd.oci.image.manifest.v1+json" \
        "$url" 2>/dev/null || echo "{}"
}

# Function to extract layer digests from manifest
get_layers() {
    local manifest="$1"

    # Extract layer digests (works for both v2 schema and OCI)
    echo "$manifest" | jq -r '.layers[]?.digest // .fsLayers[]?.blobSum // empty' 2>/dev/null | sort
}

# Function to get available tags from MCR
get_mcr_tags() {
    local url="https://${MCR_REGISTRY}/v2/${MCR_REPO}/tags/list"
    curl -sL "$url" | jq -r '.tags[]' 2>/dev/null || echo ""
}

# Function to calculate intersection of two layer sets
calculate_intersection() {
    local layers1="$1"
    local layers2="$2"

    # Count common elements
    comm -12 <(echo "$layers1") <(echo "$layers2") | wc -l
}

[ "$QUIET" = false ] && echo -e "${YELLOW}Step 1: Checking if custom image is available locally...${NC}"
if docker image inspect "$CUSTOM_IMAGE" >/dev/null 2>&1; then
    [ "$QUIET" = false ] && echo -e "${GREEN}✓ Image found locally${NC}\n"

    # Check for base image label (if added during build)
    BASE_IMAGE_LABEL=$(docker image inspect "$CUSTOM_IMAGE" --format '{{index .Config.Labels "com.rediacc.sql.base-image"}}' 2>/dev/null)

    if [ -n "$BASE_IMAGE_LABEL" ]; then
        if [ "$QUIET" = true ]; then
            echo "${BASE_IMAGE_LABEL}"
        else
            echo -e "${GREEN}=== FOUND LABEL ===${NC}"
            echo -e "${GREEN}Base image from label:${NC}"
            echo -e "  ${BLUE}${BASE_IMAGE_LABEL}${NC}\n"
            echo -e "${YELLOW}Pre-pull command:${NC}"
            echo -e "  docker pull ${BASE_IMAGE_LABEL}"
        fi
        exit 0
    fi

    # Fallback: Try to detect from Microsoft metadata
    MS_VERSION=$(docker image inspect "$CUSTOM_IMAGE" --format '{{index .Config.Labels "com.microsoft.version"}}' 2>/dev/null)
    UBUNTU_VERSION=$(docker image inspect "$CUSTOM_IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null)

    if [ -n "$MS_VERSION" ] && [ -n "$UBUNTU_VERSION" ]; then
        if [ "$QUIET" = false ]; then
            echo -e "${YELLOW}Microsoft metadata found:${NC}"
            echo -e "  SQL Server version: ${MS_VERSION}"
            echo -e "  Ubuntu version: ${UBUNTU_VERSION}"
            echo -e "${YELLOW}Searching for matching MCR tag...${NC}\n"
        fi

        # Try to find CU version from SQL version
        # Version format: 16.0.4185.3 where:
        # - 16.0 = SQL Server 2022
        # - 4185 = CU build number

        # Get layers from local image for verification
        CUSTOM_LAYERS=$(docker image inspect "$CUSTOM_IMAGE" --format '{{json .RootFS.Layers}}' | jq -r '.[]' | sort)
        CUSTOM_LAYER_COUNT=$(echo "$CUSTOM_LAYERS" | wc -l)
    fi
else
    [ "$QUIET" = false ] && echo -e "${RED}✗ Image not found locally. Trying registry API...${NC}\n"

    # Parse custom image into components
    CUSTOM_REGISTRY=$(echo "$CUSTOM_IMAGE" | cut -d'/' -f1)
    CUSTOM_REPO=$(echo "$CUSTOM_IMAGE" | cut -d'/' -f2- | cut -d':' -f1)
    CUSTOM_TAG=$(echo "$CUSTOM_IMAGE" | cut -d':' -f2)

    [ "$QUIET" = false ] && echo -e "${YELLOW}Querying registry API: ${CUSTOM_REGISTRY}/${CUSTOM_REPO}:${CUSTOM_TAG}${NC}"
    CUSTOM_MANIFEST=$(get_manifest "$CUSTOM_REGISTRY" "$CUSTOM_REPO" "$CUSTOM_TAG")

    if [ "$CUSTOM_MANIFEST" == "{}" ]; then
        [ "$QUIET" = false ] && echo -e "${RED}Failed to get manifest from registry${NC}"
        exit 1
    fi

    # Get config blob digest from manifest
    CONFIG_DIGEST=$(echo "$CUSTOM_MANIFEST" | jq -r '.config.digest // empty')

    if [ -n "$CONFIG_DIGEST" ]; then
        [ "$QUIET" = false ] && echo -e "${YELLOW}Fetching image config blob...${NC}"

        # Fetch config blob which contains diffIDs and labels
        CONFIG_BLOB=$(curl -sL "https://${CUSTOM_REGISTRY}/v2/${CUSTOM_REPO}/blobs/${CONFIG_DIGEST}")

        # Check for base image label
        BASE_IMAGE_LABEL=$(echo "$CONFIG_BLOB" | jq -r '.config.Labels."com.rediacc.sql.base-image" // empty')

        if [ -n "$BASE_IMAGE_LABEL" ]; then
            if [ "$QUIET" = true ]; then
                echo "${BASE_IMAGE_LABEL}"
            else
                echo -e "${GREEN}=== FOUND LABEL IN REGISTRY ===${NC}"
                echo -e "${GREEN}Base image from label:${NC}"
                echo -e "  ${BLUE}${BASE_IMAGE_LABEL}${NC}\n"
                echo -e "${YELLOW}Pre-pull command:${NC}"
                echo -e "  docker pull ${BASE_IMAGE_LABEL}"
            fi
            exit 0
        fi

        # Check Microsoft metadata
        MS_VERSION=$(echo "$CONFIG_BLOB" | jq -r '.config.Labels."com.microsoft.version" // empty')
        UBUNTU_VERSION=$(echo "$CONFIG_BLOB" | jq -r '.config.Labels."org.opencontainers.image.version" // empty')

        if [ -n "$MS_VERSION" ] && [ -n "$UBUNTU_VERSION" ]; then
            if [ "$QUIET" = false ]; then
                echo -e "${YELLOW}Microsoft metadata found:${NC}"
                echo -e "  SQL Server version: ${MS_VERSION}"
                echo -e "  Ubuntu version: ${UBUNTU_VERSION}"
                echo -e "${YELLOW}Searching for matching MCR tag...${NC}\n"
            fi
        fi

        # Get diffIDs for layer comparison
        CUSTOM_LAYERS=$(echo "$CONFIG_BLOB" | jq -r '.rootfs.diff_ids[]' | sort)
        CUSTOM_LAYER_COUNT=$(echo "$CUSTOM_LAYERS" | wc -l)
    else
        # Fallback to manifest layers (less accurate)
        CUSTOM_LAYERS=$(get_layers "$CUSTOM_MANIFEST")
        CUSTOM_LAYER_COUNT=$(echo "$CUSTOM_LAYERS" | wc -l)
    fi

    [ "$QUIET" = false ] && echo -e "${GREEN}✓ Got image info from registry (${CUSTOM_LAYER_COUNT} layers)${NC}\n"
fi

[ "$QUIET" = false ] && echo -e "${YELLOW}Step 2: Fetching available SQL Server tags from MCR...${NC}"
MCR_TAGS=$(get_mcr_tags)
MCR_TAG_COUNT=$(echo "$MCR_TAGS" | wc -l)

if [ -z "$MCR_TAGS" ]; then
    [ "$QUIET" = false ] && echo -e "${RED}Failed to fetch MCR tags${NC}"
    exit 1
fi

if [ "$QUIET" = false ]; then
    echo -e "${GREEN}✓ Found ${MCR_TAG_COUNT} tags on MCR${NC}"
    echo -e "${YELLOW}Sample tags:${NC}"
    echo "$MCR_TAGS" | grep "2022\|2019" | head -5 | sed 's/^/  /'
    echo ""
    echo -e "${YELLOW}Step 3: Comparing layers with MCR images (this may take a minute)...${NC}\n"
fi

BEST_MATCH_TAG=""
BEST_MATCH_COUNT=0

# Test 2022 versions matching Ubuntu version if we have it
if [ -n "$UBUNTU_VERSION" ]; then
    TEST_TAGS=$(echo "$MCR_TAGS" | grep "2022.*ubuntu-${UBUNTU_VERSION}" | head -20)
    [ "$QUIET" = false ] && echo -e "${YELLOW}Testing 2022 tags with Ubuntu ${UBUNTU_VERSION}...${NC}"
else
    # Test a larger subset of 2022 versions
    TEST_TAGS=$(echo "$MCR_TAGS" | grep "2022" | head -20)
fi

for tag in $TEST_TAGS; do
    [ "$QUIET" = false ] && echo -ne "  Testing ${tag}... "

    # Get manifest for this MCR tag
    MCR_MANIFEST=$(get_manifest "$MCR_REGISTRY" "$MCR_REPO" "$tag")

    # Get config blob to extract diffIDs
    MCR_CONFIG_DIGEST=$(echo "$MCR_MANIFEST" | jq -r '.config.digest // empty')

    if [ -n "$MCR_CONFIG_DIGEST" ]; then
        # Fetch config blob for diffIDs
        MCR_CONFIG=$(curl -sL "https://${MCR_REGISTRY}/v2/${MCR_REPO}/blobs/${MCR_CONFIG_DIGEST}" 2>/dev/null)
        MCR_LAYERS=$(echo "$MCR_CONFIG" | jq -r '.rootfs.diff_ids[]' 2>/dev/null | sort)
    else
        # Fallback to manifest digests (won't match)
        MCR_LAYERS=$(get_layers "$MCR_MANIFEST")
    fi

    # Calculate intersection
    MATCH_COUNT=$(calculate_intersection "$CUSTOM_LAYERS" "$MCR_LAYERS")

    if [ $MATCH_COUNT -gt $BEST_MATCH_COUNT ]; then
        BEST_MATCH_COUNT=$MATCH_COUNT
        BEST_MATCH_TAG=$tag
        [ "$QUIET" = false ] && echo -e "${GREEN}${MATCH_COUNT} matching layers ⭐${NC}"
    else
        [ "$QUIET" = false ] && echo -e "${MATCH_COUNT} matching layers"
    fi
done

[ "$QUIET" = false ] && echo ""
if [ -n "$BEST_MATCH_TAG" ] && [ $BEST_MATCH_COUNT -gt 0 ]; then
    DETECTED_IMAGE="${MCR_REGISTRY}/${MCR_REPO}:${BEST_MATCH_TAG}"

    if [ "$QUIET" = true ]; then
        echo "${DETECTED_IMAGE}"
    else
        echo -e "${GREEN}=== RESULT ===${NC}"
        echo -e "${GREEN}Best matching base image:${NC}"
        echo -e "  ${BLUE}${DETECTED_IMAGE}${NC}"
        echo -e "  ${YELLOW}Matching layers: ${BEST_MATCH_COUNT}/${CUSTOM_LAYER_COUNT}${NC}"
        echo ""
        echo -e "${YELLOW}Pre-pull command:${NC}"
        echo -e "  docker pull ${DETECTED_IMAGE}"
    fi
else
    [ "$QUIET" = false ] && echo -e "${RED}No matching base image found${NC}"
    exit 1
fi
