#!/bin/bash
# CI Environment Setup Script
# Sources configuration and exports variables needed for GitHub Actions

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Preserve environment variables from workflow before sourcing .env
WORKFLOW_TAG="${TAG}"
WORKFLOW_CI_MODE="${CI_MODE}"
WORKFLOW_API_TAG="${API_TAG}"
WORKFLOW_BRIDGE_TAG="${BRIDGE_TAG}"
WORKFLOW_WEB_TAG="${WEB_TAG}"

# Check if .env file exists, create from template if missing
if [ ! -f "$ELITE_DIR/.env" ]; then
    if [ -f "$ELITE_DIR/.env.template" ]; then
        echo ".env file not found. Creating from .env.template..."
        cp "$ELITE_DIR/.env.template" "$ELITE_DIR/.env"
        echo ".env file created."
    else
        echo "Error: Neither .env nor .env.template found!"
        exit 1
    fi
fi

# Source .env file for base configuration
if [ -f "$ELITE_DIR/.env" ]; then
    set -a  # automatically export all variables
    source "$ELITE_DIR/.env"
    set +a  # stop auto-exporting
fi

# Restore workflow variables if they were set (take precedence over .env)
if [ -n "$WORKFLOW_TAG" ]; then
    TAG="$WORKFLOW_TAG"
fi
if [ -n "$WORKFLOW_CI_MODE" ]; then
    CI_MODE="$WORKFLOW_CI_MODE"
    export CI_MODE
fi

# Restore per-image tags from workflow (set by console CI)
if [ -n "$WORKFLOW_API_TAG" ]; then
    API_TAG="$WORKFLOW_API_TAG"
fi
if [ -n "$WORKFLOW_BRIDGE_TAG" ]; then
    BRIDGE_TAG="$WORKFLOW_BRIDGE_TAG"
fi
if [ -n "$WORKFLOW_WEB_TAG" ]; then
    WEB_TAG="$WORKFLOW_WEB_TAG"
fi

# Function to generate secure password
# Simpler than go script's version but sufficient for ephemeral CI environments
generate_password() {
    # Generate 20-character password with guaranteed complexity
    local password=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-20)
    # Append complexity characters to ensure SQL Server requirements
    echo "${password}Aa1!"
}

# Export registry credentials
# For GitHub Container Registry, use GITHUB_TOKEN if available (GitHub Actions)
# Otherwise use provided credentials (local development)
if [ -n "$GITHUB_TOKEN" ]; then
    export DOCKER_REGISTRY_USERNAME="${GITHUB_ACTOR:-github-actions}"
    export DOCKER_REGISTRY_PASSWORD="${GITHUB_TOKEN}"
else
    export DOCKER_REGISTRY_USERNAME="${DOCKER_REGISTRY_USERNAME}"
    export DOCKER_REGISTRY_PASSWORD="${DOCKER_REGISTRY_PASSWORD}"
fi

# Override registry if VM deployment is enabled
if [ "$VM_DEPLOYMENT" == "true" ] && [ -n "$VM_REGISTRY" ]; then
    echo "VM deployment detected - using VM registry: $VM_REGISTRY"
    export DOCKER_REGISTRY="$VM_REGISTRY"
fi

# Export configuration from .env (now available after sourcing)
export SYSTEM_DOMAIN="${SYSTEM_DOMAIN}"
export DOCKER_REGISTRY="${DOCKER_REGISTRY}"
# Use TAG from environment if set (e.g., from workflow), otherwise use value from .env
export TAG="${TAG:-latest}"

# Export per-image tags (set by console CI, fallback to TAG for backwards compatibility)
export API_TAG="${API_TAG:-$TAG}"
export BRIDGE_TAG="${BRIDGE_TAG:-$TAG}"
export WEB_TAG="${WEB_TAG:-$TAG}"

# Ensure DOCKER_BRIDGE_IMAGE uses BRIDGE_TAG (required for middleware to create bridge containers)
export DOCKER_BRIDGE_IMAGE="${DOCKER_REGISTRY}/bridge:${BRIDGE_TAG}"

# Set Docker network name for bridge containers (standalone mode uses rediacc_internet)
export DOCKER_INTERNET_NETWORK="rediacc_internet"

# Set Docker bridge network mode to "host" for CI
# This allows bridge containers to access the host's localhost (127.0.0.1) for SSH connections
# In production/cloud mode, this defaults to the internet network for proper isolation
export DOCKER_BRIDGE_NETWORK_MODE="host"

# Set Docker bridge API URL for host networking
# When bridges use host networking, they cannot resolve Docker container names
# Must use localhost since nginx exposes port 80 on the host
export DOCKER_BRIDGE_API_URL="http://localhost"

# Generate database passwords
export MSSQL_SA_PASSWORD="$(generate_password)"
export MSSQL_RA_PASSWORD="$(generate_password)"
export REDIACC_DATABASE_NAME="${REDIACC_DATABASE_NAME:-RediaccMiddleware}"
export REDIACC_SQL_USERNAME="${REDIACC_SQL_USERNAME:-rediacc}"

# Mask passwords in GitHub Actions logs
if [ -n "$GITHUB_ACTIONS" ]; then
    echo "::add-mask::$MSSQL_SA_PASSWORD"
    echo "::add-mask::$MSSQL_RA_PASSWORD"
fi

# Build connection string (same format as go script)
export CONNECTION_STRING="Server=sql,1433;Database=${REDIACC_DATABASE_NAME};User Id=${REDIACC_SQL_USERNAME};Password=\"${MSSQL_RA_PASSWORD}\";TrustServerCertificate=True;Application Name=${REDIACC_DATABASE_NAME};Max Pool Size=32;Min Pool Size=2;Connection Lifetime=120;Connection Timeout=15;Command Timeout=30;Pooling=true;MultipleActiveResultSets=false;Packet Size=32768"

# Don't set INSTANCE_NAME for CI - use standalone mode with auto-created networks
# Cloud mode (INSTANCE_NAME set) requires pre-existing external networks which CI doesn't have
# export INSTANCE_NAME="ci-${GITHUB_RUN_ID}"

# Export SYSTEM_DEFAULT_* variables to GITHUB_ENV for subsequent steps (e.g., ops action)
if [ -n "$GITHUB_ENV" ]; then
    echo "SYSTEM_DEFAULT_TEAM_NAME=${SYSTEM_DEFAULT_TEAM_NAME}" >> "$GITHUB_ENV"
    echo "SYSTEM_DEFAULT_REGION_NAME=${SYSTEM_DEFAULT_REGION_NAME}" >> "$GITHUB_ENV"
    echo "SYSTEM_DEFAULT_BRIDGE_NAME=${SYSTEM_DEFAULT_BRIDGE_NAME}" >> "$GITHUB_ENV"
fi
