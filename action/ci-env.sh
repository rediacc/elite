#!/bin/bash
# CI Environment Setup Script
# Sources configuration and exports variables needed for GitHub Actions

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source .env file for base configuration
if [ -f "$ELITE_DIR/.env" ]; then
    set -a  # automatically export all variables
    source "$ELITE_DIR/.env"
    set +a  # stop auto-exporting
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

# Export configuration from .env (now available after sourcing)
export SYSTEM_DOMAIN="${SYSTEM_DOMAIN}"
export DOCKER_REGISTRY="${DOCKER_REGISTRY}"
export TAG="${TAG}"

# Ensure DOCKER_BRIDGE_IMAGE includes the tag (required for middleware to create bridge containers)
export DOCKER_BRIDGE_IMAGE="${DOCKER_REGISTRY}/bridge:${TAG}"

# Set Docker network name for bridge containers (standalone mode uses rediacc_internet)
export DOCKER_INTERNET_NETWORK="rediacc_internet"

# Set Docker bridge network mode to "host" for CI
# This allows bridge containers to access the host's localhost (127.0.0.1) for SSH connections
# In production/cloud mode, this defaults to the internet network for proper isolation
export DOCKER_BRIDGE_NETWORK_MODE="host"

# Generate database passwords
export MSSQL_SA_PASSWORD="$(generate_password)"
export MSSQL_RA_PASSWORD="$(generate_password)"
export REDIACC_DATABASE_NAME="${REDIACC_DATABASE_NAME:-RediaccMiddleware}"

# Mask passwords in GitHub Actions logs
if [ -n "$GITHUB_ACTIONS" ]; then
    echo "::add-mask::$MSSQL_SA_PASSWORD"
    echo "::add-mask::$MSSQL_RA_PASSWORD"
fi

# Build connection string (same format as go script)
export CONNECTION_STRING="Server=sql,1433;Database=${REDIACC_DATABASE_NAME};User Id=rediacc;Password=\"${MSSQL_RA_PASSWORD}\";TrustServerCertificate=True;Application Name=${REDIACC_DATABASE_NAME};Max Pool Size=32;Min Pool Size=2;Connection Lifetime=120;Connection Timeout=15;Command Timeout=30;Pooling=true;MultipleActiveResultSets=false;Packet Size=32768"

# Don't set INSTANCE_NAME for CI - use standalone mode with auto-created networks
# Cloud mode (INSTANCE_NAME set) requires pre-existing external networks which CI doesn't have
# export INSTANCE_NAME="ci-${GITHUB_RUN_ID}"
