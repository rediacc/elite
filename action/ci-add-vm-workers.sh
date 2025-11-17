#!/bin/bash
# CI Script: Register VM workers with Rediacc middleware
# Discovers VMs from setup-vms action outputs and registers them as machines

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$ELITE_DIR/../.." && pwd)"

echo "============================================"
echo "Registering VM workers with middleware"
echo "============================================"

# Source CI environment variables
if [ -f "$SCRIPT_DIR/ci-env.sh" ]; then
    source "$SCRIPT_DIR/ci-env.sh"
else
    echo "Error: ci-env.sh not found"
    exit 1
fi

# Configuration from environment
PROVIDER="${PROVIDER:-kvm}"
WORKER_IPS="${WORKER_IPS}"
BRIDGE_IP="${BRIDGE_IP}"
MACHINE_USER="${VM_USR:-runner}"
MACHINE_DATASTORE="/mnt/datastore"

# Validate required inputs
if [ -z "$WORKER_IPS" ]; then
    echo "Error: WORKER_IPS environment variable not set"
    echo "This script should be called after setup-vms action"
    exit 1
fi

# Validate required environment variables
if [ -z "$SYSTEM_ADMIN_EMAIL" ] || [ -z "$SYSTEM_ADMIN_PASSWORD" ]; then
    echo "Error: SYSTEM_ADMIN_EMAIL or SYSTEM_ADMIN_PASSWORD not set"
    exit 1
fi

# Set API URL for CLI (HTTP_PORT is set by ci-env.sh from .env)
if [ -n "$HTTP_PORT" ] && [ "$HTTP_PORT" != "80" ]; then
    export SYSTEM_API_URL="http://localhost:${HTTP_PORT}/api"
else
    export SYSTEM_API_URL="http://localhost/api"
fi

echo "Configuration:"
echo "  Provider: $PROVIDER"
echo "  Worker IPs: $WORKER_IPS"
echo "  Bridge IP: $BRIDGE_IP"
echo "  API URL: $SYSTEM_API_URL"
echo ""

# Helper function to run CLI command
_run_cli_command() {
    rediacc "$@"
}

# Helper function to generate machine name from IP
_generate_machine_name() {
    local ip="$1"
    local provider="$2"

    # Replace dots with dashes for valid machine names
    local ip_sanitized=$(echo "$ip" | tr '.' '-')

    # Generate name: {provider}-{ip-with-dashes}
    echo "${provider}-${ip_sanitized}"
}

# Helper function to extract SSH host key
_extract_host_key() {
    local ip="$1"

    # Try ed25519 first, fallback to RSA
    local host_key=$(ssh-keyscan -t ed25519 "$ip" 2>/dev/null | head -1)
    if [ -z "$host_key" ]; then
        host_key=$(ssh-keyscan -t rsa "$ip" 2>/dev/null | head -1)
    fi

    if [ -z "$host_key" ]; then
        echo "Error: Could not extract SSH host key for $ip" >&2
        return 1
    fi

    echo "$host_key"
}

# Helper function to register a single machine
_register_machine() {
    local ip="$1"
    local machine_name="$2"
    local host_key="$3"

    # Create machine vault JSON
    local machine_vault=$(jq -n \
        --arg alias "$machine_name" \
        --arg ip "$ip" \
        --arg user "$MACHINE_USER" \
        --arg datastore "$MACHINE_DATASTORE" \
        --arg host_entry "$host_key" \
        '{
            alias: $alias,
            ip: $ip,
            user: $user,
            datastore: $datastore,
            host_entry: $host_entry,
            ssh_password: ""
        }')

    # Register machine with middleware
    if _run_cli_command CreateMachine \
        --teamName "${SYSTEM_DEFAULT_TEAM_NAME}" \
        --bridgeName "${SYSTEM_DEFAULT_BRIDGE_NAME}" \
        --machineName "$machine_name" \
        --machineVault "$machine_vault" 2>&1 | grep -q "Successfully executed"; then
        echo "✓ Registered machine: $machine_name ($ip)"
        return 0
    else
        echo "⚠ Could not register machine: $machine_name (may already exist)"
        return 1
    fi
}

echo "Step 1: Logging in to middleware"
echo "---------------------------------"

# Login to middleware (suppress output to avoid password leakage)
if ! _run_cli_command auth login --endpoint "$SYSTEM_API_URL" --email "$SYSTEM_ADMIN_EMAIL" --password "$SYSTEM_ADMIN_PASSWORD" >/dev/null 2>&1; then
    echo "Error: Could not login to middleware"
    echo "Retrying with verbose output..."
    _run_cli_command auth login --endpoint "$SYSTEM_API_URL" --email "$SYSTEM_ADMIN_EMAIL" --password "$SYSTEM_ADMIN_PASSWORD"
    exit 1
fi
echo "✓ Logged in successfully"

# Wait a moment for token to be saved
sleep 0.5

echo ""
echo "Step 2: Registering worker machines"
echo "------------------------------------"

# Parse comma-separated worker IPs into array
IFS=',' read -ra WORKER_IP_ARRAY <<< "$WORKER_IPS"

# Track registration success
REGISTERED_COUNT=0
FAILED_COUNT=0

# Register each worker
for worker_ip in "${WORKER_IP_ARRAY[@]}"; do
    # Trim whitespace
    worker_ip=$(echo "$worker_ip" | xargs)

    if [ -z "$worker_ip" ]; then
        continue
    fi

    echo ""
    echo "Processing worker: $worker_ip"

    # Generate machine name
    machine_name=$(_generate_machine_name "$worker_ip" "$PROVIDER")
    echo "  Machine name: $machine_name"

    # Extract SSH host key
    echo "  Extracting SSH host key..."
    if ! host_key=$(_extract_host_key "$worker_ip"); then
        echo "  ✗ Failed to extract host key, skipping"
        ((FAILED_COUNT++))
        continue
    fi
    echo "  ✓ Host key extracted: ${host_key:0:50}..."

    # Register machine
    echo "  Registering with middleware..."
    if _register_machine "$worker_ip" "$machine_name" "$host_key"; then
        ((REGISTERED_COUNT++))
    else
        ((FAILED_COUNT++))
    fi
done

# Also register bridge if provided
if [ -n "$BRIDGE_IP" ]; then
    echo ""
    echo "Processing bridge: $BRIDGE_IP"

    bridge_name=$(_generate_machine_name "$BRIDGE_IP" "$PROVIDER")
    # Override name for bridge
    bridge_name="${PROVIDER}-bridge"
    echo "  Machine name: $bridge_name"

    echo "  Extracting SSH host key..."
    if host_key=$(_extract_host_key "$BRIDGE_IP"); then
        echo "  ✓ Host key extracted: ${host_key:0:50}..."

        echo "  Registering with middleware..."
        if _register_machine "$BRIDGE_IP" "$bridge_name" "$host_key"; then
            ((REGISTERED_COUNT++))
        else
            ((FAILED_COUNT++))
        fi
    else
        echo "  ✗ Failed to extract host key, skipping"
        ((FAILED_COUNT++))
    fi
fi

echo ""
echo "Step 3: Logging out"
echo "-------------------"

# Logout
_run_cli_command auth logout >/dev/null 2>&1 || true
echo "✓ Logged out"

echo ""
echo "============================================"
echo "✓ VM worker registration complete"
echo "============================================"
echo ""
echo "Summary:"
echo "  Successfully registered: $REGISTERED_COUNT"
echo "  Failed or skipped: $FAILED_COUNT"
echo ""
echo "Note: VMs are already configured by setup-vms action."
echo "      No setup tasks queued."
echo ""
