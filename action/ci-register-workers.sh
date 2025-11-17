#!/bin/bash
# CI Script: Register worker machines with Rediacc middleware
# Discovers infrastructure (VMs, bare metal, etc.) and registers as machines

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$ELITE_DIR/../.." && pwd)"

echo "============================================"
echo "Registering worker machines with middleware"
echo "============================================"

# Source CI environment variables
if [ -f "$SCRIPT_DIR/ci-env.sh" ]; then
    source "$SCRIPT_DIR/ci-env.sh"
else
    echo "Error: ci-env.sh not found"
    exit 1
fi

# Configuration from environment
# Note: Workflow sets VM_WORKER_IPS, VM_BRIDGE_IP, and VM_PROVIDER
PROVIDER="${VM_PROVIDER:-${PROVIDER:-kvm}}"
WORKER_IPS="${VM_WORKER_IPS:-${WORKER_IPS}}"
BRIDGE_IP="${VM_BRIDGE_IP:-${BRIDGE_IP}}"
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

# Install rediacc CLI from PyPI if not already installed
# Skip installation if REDIACC_SKIP_CLI_INSTALL is set (e.g., when testing local CLI changes)
if [ "$REDIACC_SKIP_CLI_INSTALL" = "true" ]; then
    echo "⚠ Skipping CLI installation (REDIACC_SKIP_CLI_INSTALL=true)"
    if ! command -v rediacc &> /dev/null; then
        echo "Error: REDIACC_SKIP_CLI_INSTALL is set but rediacc CLI is not installed"
        exit 1
    fi
    echo "✓ Using existing rediacc CLI installation"
elif ! command -v rediacc &> /dev/null; then
    # Derive CLI version from TAG environment variable (used for Docker images)
    # TAG format: 0.1.67, 0.2.1, or latest (no v prefix)
    CLI_VERSION="${TAG:-latest}"

    if [ "$CLI_VERSION" = "latest" ]; then
        echo "Installing latest rediacc CLI from PyPI..."
        pip install --quiet rediacc
    else
        # If version starts with comparison operator (>=, ==, ~=, etc.), use as-is
        # Otherwise, add == for exact version match
        case "$CLI_VERSION" in
            [\>\<\=\~\!]*)
                echo "Installing rediacc CLI with constraint: $CLI_VERSION..."
                pip install --quiet "rediacc${CLI_VERSION}"
                ;;
            *)
                echo "Installing rediacc CLI version: $CLI_VERSION..."
                # Try specific version, fall back to latest if not available on PyPI
                if ! pip install --quiet "rediacc==$CLI_VERSION" 2>/dev/null; then
                    echo "⚠ Version $CLI_VERSION not available on PyPI, falling back to latest..."
                    pip install --quiet rediacc
                fi
                ;;
        esac
    fi
    echo "✓ rediacc CLI installed"
else
    echo "✓ rediacc CLI already installed"
fi

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

# Helper function to queue setup task for a machine
_queue_setup_task() {
    local ip="$1"
    local machine_name="$2"
    local host_key="$3"

    # Build the setup vault with proper structure
    local setup_vault=$(jq -n \
        --arg team "$SYSTEM_DEFAULT_TEAM_NAME" \
        --arg machine "$machine_name" \
        --arg ip "$ip" \
        --arg user "$MACHINE_USER" \
        --arg datastore "$MACHINE_DATASTORE" \
        --arg host_entry "$host_key" \
        --arg api_url "$SYSTEM_API_URL" \
        --argjson company_vault "$COMPANY_VAULT_JSON" \
        --argjson team_vault "$TEAM_VAULT_JSON" \
        '{
            function: "setup",
            machine: $machine,
            team: $team,
            params: {
                datastore_size: "95%",
                source: "apt-repo",
                rclone_source: "install-script",
                docker_source: "docker-repo",
                install_amd_driver: "auto",
                install_nvidia_driver: "auto"
            },
            contextData: {
                GENERAL_SETTINGS: ($company_vault + $team_vault + {
                    SYSTEM_API_URL: $api_url,
                    MACHINES: {
                        ($machine): {
                            IP: $ip,
                            USER: $user,
                            DATASTORE: $datastore,
                            HOST_ENTRY: $host_entry
                        }
                    }
                }),
                MACHINES: {
                    ($machine): {
                        IP: $ip,
                        USER: $user,
                        DATASTORE: $datastore,
                        HOST_ENTRY: $host_entry
                    }
                },
                company: $company_vault
            }
        }')

    # Queue setup task
    if _run_cli_command CreateQueueItem \
        --teamName "$SYSTEM_DEFAULT_TEAM_NAME" \
        --machineName "$machine_name" \
        --bridgeName "${SYSTEM_DEFAULT_BRIDGE_NAME}" \
        --queueVault "$setup_vault" \
        --priority 1 2>&1 | grep -q "Successfully executed"; then
        echo "✓ Queued setup task for: $machine_name"
        return 0
    else
        echo "⚠ Could not queue setup task for: $machine_name"
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

# Fetch vault data for setup tasks
echo ""
echo "Step 2: Fetching vault data for setup tasks"
echo "---------------------------------------------"

# Fetch company credential and vault data
echo "Fetching company vault..."
COMPANY_RESPONSE=$(_run_cli_command GetCompanyVault --output json)

if [ $? -ne 0 ]; then
    echo "Warning: Could not fetch company vault data"
    echo "Setup tasks will not be queued"
    SKIP_SETUP=true
else
    # Extract company credential (becomes COMPANY_ID)
    COMPANY_CREDENTIAL=$(echo "$COMPANY_RESPONSE" | jq -r '.data.result[0].companyCredential // .data.result[0].CompanyCredential')
    COMPANY_VAULT_STR=$(echo "$COMPANY_RESPONSE" | jq -r '.data.result[0].vaultContent // .data.result[0].VaultContent')
    echo "✓ Company credential: ${COMPANY_CREDENTIAL:0:8}..."

    # Fetch team vault data
    echo "Fetching team vault..."
    TEAMS_RESPONSE=$(_run_cli_command GetCompanyTeams --output json)

    if [ $? -ne 0 ]; then
        echo "Warning: Could not fetch teams data"
        echo "Setup tasks will not be queued"
        SKIP_SETUP=true
    else
        # Find the default team and extract its vault
        TEAM_VAULT_STR=$(echo "$TEAMS_RESPONSE" | jq -r --arg team "$SYSTEM_DEFAULT_TEAM_NAME" '
            .data.result[] | select(.teamName == $team or .TeamName == $team) | (.vaultContent // .VaultContent)
        ')

        # Parse vaults and add COMPANY_ID
        COMPANY_VAULT_JSON=$(echo "$COMPANY_VAULT_STR" | jq --arg id "$COMPANY_CREDENTIAL" '. + {COMPANY_ID: $id}')
        TEAM_VAULT_JSON=$(echo "$TEAM_VAULT_STR" | jq '.')
        echo "✓ Vault data fetched successfully"
    fi
fi

echo ""
echo "Step 3: Registering worker machines"
echo "------------------------------------"

# Parse comma-separated worker IPs into array
IFS=',' read -ra WORKER_IP_ARRAY <<< "$WORKER_IPS"

# Track registration and setup success
REGISTERED_COUNT=0
FAILED_COUNT=0
SETUP_QUEUED_COUNT=0
SETUP_FAILED_COUNT=0

# Store machine info for setup queueing
declare -A REGISTERED_MACHINES

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
        # Store for setup queueing
        REGISTERED_MACHINES["$machine_name"]="$worker_ip|$host_key"
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
            # Store for setup queueing
            REGISTERED_MACHINES["$bridge_name"]="$BRIDGE_IP|$host_key"
        else
            ((FAILED_COUNT++))
        fi
    else
        echo "  ✗ Failed to extract host key, skipping"
        ((FAILED_COUNT++))
    fi
fi

# Queue setup tasks for all machines
if [ "$SKIP_SETUP" != "true" ] && [ ${#REGISTERED_MACHINES[@]} -gt 0 ]; then
    echo ""
    echo "Step 4: Queueing setup tasks"
    echo "----------------------------"

    for machine_name in "${!REGISTERED_MACHINES[@]}"; do
        # Parse stored data
        IFS='|' read -r machine_ip machine_host_key <<< "${REGISTERED_MACHINES[$machine_name]}"

        echo ""
        echo "Queueing setup for: $machine_name ($machine_ip)"
        if _queue_setup_task "$machine_ip" "$machine_name" "$machine_host_key"; then
            ((SETUP_QUEUED_COUNT++))
        else
            ((SETUP_FAILED_COUNT++))
        fi
    done
fi

echo ""
echo "Step 5: Logging out"
echo "-------------------"

# Logout
_run_cli_command auth logout >/dev/null 2>&1 || true
echo "✓ Logged out"

echo ""
echo "============================================"
echo "✓ Worker machine registration complete"
echo "============================================"
echo ""
echo "Summary:"
echo "  Successfully registered: $REGISTERED_COUNT"
echo "  Failed or skipped: $FAILED_COUNT"
echo "  Setup tasks queued: $SETUP_QUEUED_COUNT"
echo "  Setup tasks failed: $SETUP_FAILED_COUNT"
echo ""
echo "Note: Bridge will process setup tasks to install required dependencies."
echo "      This applies to all machines regardless of provider ($PROVIDER)."
echo ""
