#!/bin/bash
# CI Script: Register worker machines with Rediacc middleware
# Discovers infrastructure (VMs, bare metal, etc.) and registers as machines

set -e
set -o pipefail

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
MACHINE_DATASTORE="/mnt/rediacc"

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

# Set master password for non-interactive vault encryption
export REDIACC_MASTER_PASSWORD="$SYSTEM_ADMIN_PASSWORD"

echo "Configuration:"
echo "  Provider: $PROVIDER"
echo "  Worker IPs: $WORKER_IPS"
echo "  Bridge IP: $BRIDGE_IP"
echo "  API URL: $SYSTEM_API_URL"
echo ""

# Install rdc CLI from local /npm/ (embedded in web image)
# Note: rdc is NOT published to public npm - must use embedded package
# Skip installation if REDIACC_SKIP_CLI_INSTALL is set (e.g., when testing local CLI changes)
LOCAL_NPM="http://localhost/npm/"

if [ "$REDIACC_SKIP_CLI_INSTALL" = "true" ]; then
    echo "⚠ Skipping CLI installation (REDIACC_SKIP_CLI_INSTALL=true)"
    if ! command -v rdc &> /dev/null; then
        echo "Error: REDIACC_SKIP_CLI_INSTALL is set but rdc CLI is not installed"
        exit 1
    fi
    echo "✓ Using existing rdc CLI installation"
elif ! command -v rdc &> /dev/null; then
    # Check if CLI packages are embedded in the web image
    echo "Checking for embedded CLI packages..."
    if ! curl -sf "http://localhost/cli-packages.json" > /dev/null 2>&1; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "ERROR: CLI packages not embedded in web image"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "The web Docker image does not have CLI packages embedded."
        echo "Rebuild the images with:"
        echo "  ./go build npm     # Build Node.js CLI package"
        echo "  ./go build prod    # Build Docker images (embeds CLI packages)"
        echo ""
        exit 1
    fi

    # Install rdc CLI from local npm mirror
    echo "Installing rdc CLI (Node.js)..."
    CLI_VERSION="${TAG:-latest}"
    if [ "$CLI_VERSION" = "latest" ]; then
        LOCAL_TGZ="${LOCAL_NPM}rediacc-cli-latest.tgz"
    else
        LOCAL_TGZ="${LOCAL_NPM}rediacc-cli-${CLI_VERSION}.tgz"
        # Fallback to latest if specific version not found
        if ! curl -sf "$LOCAL_TGZ" -o /dev/null 2>/dev/null; then
            echo "⚠ Version $CLI_VERSION not found, using latest"
            LOCAL_TGZ="${LOCAL_NPM}rediacc-cli-latest.tgz"
        fi
    fi

    install_output=$(npm install -g "$LOCAL_TGZ" 2>&1)
    install_status=$?
    if [ $install_status -eq 0 ]; then
        echo "✓ Installed rdc from local /npm/"
    else
        echo "ERROR: Failed to install rdc from local /npm/"
        echo "$install_output"
        exit 1
    fi
else
    echo "✓ rdc CLI already installed"
fi

# Helper function to run CLI command
_run_cli_command() {
    rdc "$@"
}

# Helper function to generate machine name from IP
_generate_machine_name() {
    local ip="$1"
    local sequence="$2"

    # Generate clean sequential name for demos: machine-1, machine-2, etc.
    echo "machine-${sequence}"
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

    # Register machine with middleware (Console CLI syntax)
    local output
    output=$(_run_cli_command machine create "$machine_name" \
        -t "${SYSTEM_DEFAULT_TEAM_NAME}" \
        -b "${SYSTEM_DEFAULT_BRIDGE_NAME}" \
        --vault "$machine_vault" 2>&1)
    local exit_code=$?

    # Show output for debugging
    echo "  CLI output: $output"
    echo "  Exit code: $exit_code"

    if echo "$output" | grep -qi "created\|success"; then
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

    # Queue setup task (Console CLI syntax)
    if _run_cli_command queue create \
        -f "setup" \
        -t "$SYSTEM_DEFAULT_TEAM_NAME" \
        -m "$machine_name" \
        -b "${SYSTEM_DEFAULT_BRIDGE_NAME}" \
        --vault "$setup_vault" \
        -p 1 2>&1 | grep -qi "created\|task.*id\|success"; then
        echo "✓ Queued setup task for: $machine_name"
        return 0
    else
        echo "⚠ Could not queue setup task for: $machine_name"
        return 1
    fi
}

echo "Step 1: Logging in to middleware"
echo "---------------------------------"

# Login to middleware (Console CLI syntax - suppress output to avoid password leakage)
if ! _run_cli_command auth login --endpoint "$SYSTEM_API_URL" -e "$SYSTEM_ADMIN_EMAIL" -p "$SYSTEM_ADMIN_PASSWORD" >/dev/null 2>&1; then
    echo "Error: Could not login to middleware"
    echo "Retrying with verbose output..."
    _run_cli_command auth login --endpoint "$SYSTEM_API_URL" -e "$SYSTEM_ADMIN_EMAIL" -p "$SYSTEM_ADMIN_PASSWORD"
    exit 1
fi
echo "✓ Logged in successfully"

# Wait a moment for token to be saved
sleep 0.5

# Fetch vault data for setup tasks
echo ""
echo "Step 2: Fetching vault data for setup tasks"
echo "---------------------------------------------"

# Fetch company credential and vault data (Console CLI syntax)
echo "Fetching company vault..."
COMPANY_RESPONSE=$(_run_cli_command company vault get -o json 2>&1 | sed -n '/^{/,$p')
CLI_EXIT_CODE="${PIPESTATUS[0]}"

if [ "$CLI_EXIT_CODE" -ne 0 ] || [ -z "$COMPANY_RESPONSE" ]; then
    echo "Warning: Could not fetch company vault data"
    echo "Setup tasks will not be queued"
    SKIP_SETUP=true
else
    # Console CLI returns: { vault: string, vaultVersion: number, companyCredential: string }
    COMPANY_CREDENTIAL=$(echo "$COMPANY_RESPONSE" | jq -r '.companyCredential // empty')
    COMPANY_VAULT_STR=$(echo "$COMPANY_RESPONSE" | jq -r '.vault // "{}"')
    echo "✓ Company credential: ${COMPANY_CREDENTIAL:0:8}..."

    # Fetch team vault data (Console CLI returns array directly)
    echo "Fetching team vault..."
    TEAMS_RESPONSE=$(_run_cli_command team list -o json 2>&1 | sed -n '/^\[/,$p')
    CLI_EXIT_CODE="${PIPESTATUS[0]}"

    if [ "$CLI_EXIT_CODE" -ne 0 ] || [ -z "$TEAMS_RESPONSE" ]; then
        echo "Warning: Could not fetch teams data"
        echo "Setup tasks will not be queued"
        SKIP_SETUP=true
    else
        # Console CLI returns array directly (no .data.result wrapper)
        TEAM_VAULT_STR=$(echo "$TEAMS_RESPONSE" | jq -r --arg team "$SYSTEM_DEFAULT_TEAM_NAME" '
            .[] | select(.teamName == $team or .TeamName == $team) | (.vaultContent // .VaultContent // "{}")
        ')

        # Parse vaults and add COMPANY_ID
        COMPANY_VAULT_JSON=$(echo "$COMPANY_VAULT_STR" | jq --arg id "$COMPANY_CREDENTIAL" '. + {COMPANY_ID: $id}' 2>/dev/null || echo '{}')
        TEAM_VAULT_JSON=$(echo "$TEAM_VAULT_STR" | jq '.' 2>/dev/null || echo '{}')
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

# Machine counter for sequential naming
MACHINE_SEQUENCE=0

# Register each worker
for worker_ip in "${WORKER_IP_ARRAY[@]}"; do
    # Trim whitespace
    worker_ip=$(echo "$worker_ip" | xargs)

    if [ -z "$worker_ip" ]; then
        continue
    fi

    # Increment sequence for each machine
    ((MACHINE_SEQUENCE++)) || true

    echo ""
    echo "Processing worker: $worker_ip"

    # Generate machine name with sequential number
    machine_name=$(_generate_machine_name "$worker_ip" "$MACHINE_SEQUENCE")
    echo "  Machine name: $machine_name"

    # Extract SSH host key
    echo "  Extracting SSH host key..."
    if ! host_key=$(_extract_host_key "$worker_ip"); then
        echo "  ✗ Failed to extract host key, skipping"
        ((FAILED_COUNT++)) || true
        continue
    fi
    echo "  ✓ Host key extracted: ${host_key:0:50}..."

    # Register machine
    echo "  Registering with middleware..."
    if _register_machine "$worker_ip" "$machine_name" "$host_key"; then
        ((REGISTERED_COUNT++)) || true
        # Store for setup queueing
        REGISTERED_MACHINES["$machine_name"]="$worker_ip|$host_key"
    else
        ((FAILED_COUNT++)) || true
    fi
done

# Note: Bridge VM is NOT registered as a machine
# The bridge is infrastructure that manages workers, not a worker itself

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
            ((SETUP_QUEUED_COUNT++)) || true
        else
            ((SETUP_FAILED_COUNT++)) || true
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
