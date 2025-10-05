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

# Export registry credentials (pass-through from environment)
export DOCKER_REGISTRY_USERNAME="${DOCKER_REGISTRY_USERNAME}"
export DOCKER_REGISTRY_PASSWORD="${DOCKER_REGISTRY_PASSWORD}"

# Export configuration from .env (now available after sourcing)
export SYSTEM_DOMAIN="${SYSTEM_DOMAIN}"
export DOCKER_REGISTRY="${DOCKER_REGISTRY}"
export TAG="${TAG}"

# Generate database passwords
export MSSQL_SA_PASSWORD="$(generate_password)"
export MSSQL_RA_PASSWORD="$(generate_password)"
export REDIACC_DATABASE_NAME="${REDIACC_DATABASE_NAME:-RediaccMiddleware}"

# Build connection string (same format as go script)
export CONNECTION_STRING="Server=sql,1433;Database=${REDIACC_DATABASE_NAME};User Id=rediacc;Password=\"${MSSQL_RA_PASSWORD}\";TrustServerCertificate=True;Application Name=${REDIACC_DATABASE_NAME};Max Pool Size=32;Min Pool Size=2;Connection Lifetime=120;Connection Timeout=15;Command Timeout=30;Pooling=true;MultipleActiveResultSets=false;Packet Size=32768"

# Set instance name for CI (uses GitHub's run ID for uniqueness)
export INSTANCE_NAME="ci-${GITHUB_RUN_ID}"
