#!/bin/bash
# CI Script: Add localhost as a machine named 'local' for GitHub Actions
# This enables the CI environment to execute tasks on itself via SSH

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$ELITE_DIR/../.." && pwd)"

echo "============================================"
echo "Setting up localhost as 'local' machine"
echo "============================================"

# Source CI environment variables
if [ -f "$SCRIPT_DIR/ci-env.sh" ]; then
    source "$SCRIPT_DIR/ci-env.sh"
else
    echo "Error: ci-env.sh not found"
    exit 1
fi

# Configuration
MACHINE_NAME="local"
MACHINE_IP="127.0.0.1"
MACHINE_USER="${USER:-runner}"
MACHINE_DATASTORE="/tmp/rediacc-datastore"
SSH_DIR="$HOME/.ssh"

# Find existing SSH key (prefer ed25519, then rsa)
SSH_KEY_FILE=""
SSH_PUB_KEY_FILE=""
if [ -f "$SSH_DIR/id_ed25519" ]; then
    SSH_KEY_FILE="$SSH_DIR/id_ed25519"
    SSH_PUB_KEY_FILE="$SSH_DIR/id_ed25519.pub"
    echo "Using existing ed25519 SSH key"
elif [ -f "$SSH_DIR/id_rsa" ]; then
    SSH_KEY_FILE="$SSH_DIR/id_rsa"
    SSH_PUB_KEY_FILE="$SSH_DIR/id_rsa.pub"
    echo "Using existing RSA SSH key"
fi

# Install rediacc CLI from PyPI if not already installed
if ! command -v rediacc &> /dev/null; then
    # Use REDIACC_CLI_VERSION env var if set, otherwise install latest
    CLI_VERSION="${REDIACC_CLI_VERSION:-latest}"

    if [ "$CLI_VERSION" = "latest" ]; then
        echo "Installing latest rediacc CLI from PyPI..."
        pip install --quiet rediacc
    else
        # If version starts with comparison operator (>=, ==, ~=, etc.), use as-is
        # Otherwise, add == for exact version match
        if [[ "$CLI_VERSION" =~ ^[><=~!] ]]; then
            echo "Installing rediacc CLI with constraint: $CLI_VERSION..."
            pip install --quiet "rediacc${CLI_VERSION}"
        else
            echo "Installing rediacc CLI version: $CLI_VERSION..."
            pip install --quiet "rediacc==$CLI_VERSION"
        fi
    fi
    echo "✓ rediacc CLI installed"
else
    echo "✓ rediacc CLI already installed"
fi

# Helper function to run CLI command
_run_cli_command() {
    rediacc "$@"
}

echo ""
echo "Step 1: Setting up SSH for localhost connection"
echo "------------------------------------------------"

# Ensure SSH directory exists with correct permissions
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Fix home directory permissions for SSH (must not be world-writable)
chmod 755 "$HOME" || {
    echo "Warning: Could not fix home directory permissions"
}

# Generate SSH key pair only if no existing keys found
if [ -z "$SSH_KEY_FILE" ]; then
    echo "No existing SSH keys found, generating new key pair..."
    SSH_KEY_FILE="$SSH_DIR/id_rsa"
    SSH_PUB_KEY_FILE="$SSH_DIR/id_rsa.pub"
    ssh-keygen -t rsa -b 2048 -f "$SSH_KEY_FILE" -q -N "" -C "github-actions-runner"
    echo "SSH key generated: $SSH_KEY_FILE"
fi

# Add public key to authorized_keys (if not already present)
echo "Adding public key to authorized_keys..."
touch "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"

# Check if key is already in authorized_keys
if ! grep -qF "$(cat "$SSH_PUB_KEY_FILE")" "$SSH_DIR/authorized_keys" 2>/dev/null; then
    cat "$SSH_PUB_KEY_FILE" >> "$SSH_DIR/authorized_keys"
    echo "✓ Public key added to authorized_keys"
else
    echo "✓ Public key already in authorized_keys"
fi

# Test SSH connection to localhost
echo "Testing SSH connection to localhost..."
if ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$MACHINE_USER@$MACHINE_IP" "echo 'SSH connection successful'" 2>&1 | grep -q "successful"; then
    echo "✓ SSH connection to localhost works"
else
    echo "✗ SSH connection test failed"
    echo "Attempting to diagnose..."

    # Try to start SSH service if not running (on self-hosted runners)
    if ! pgrep -x sshd > /dev/null; then
        echo "SSH service not running. Attempting to start..."
        sudo service ssh start || sudo systemctl start sshd || {
            echo "Could not start SSH service. It may not be installed."
            echo "GitHub-hosted runners should have SSH pre-configured."
        }
    fi

    # Retry connection
    if ! ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$MACHINE_USER@$MACHINE_IP" "echo 'SSH connection successful'" 2>&1 | grep -q "successful"; then
        echo "Error: SSH connection still failing"
        exit 1
    fi
fi

echo ""
echo "Step 2: Creating machine datastore"
echo "-----------------------------------"

# Create datastore directory
mkdir -p "$MACHINE_DATASTORE"
chmod 755 "$MACHINE_DATASTORE"
echo "✓ Created datastore at: $MACHINE_DATASTORE"

echo ""
echo "Step 3: Extracting SSH host key"
echo "--------------------------------"

# Get localhost SSH host key
HOST_KEY=$(ssh-keyscan -t ed25519 127.0.0.1 2>/dev/null | head -1)
if [ -z "$HOST_KEY" ]; then
    # Fallback to rsa if ed25519 not available
    HOST_KEY=$(ssh-keyscan -t rsa 127.0.0.1 2>/dev/null | head -1)
fi

if [ -z "$HOST_KEY" ]; then
    echo "Error: Could not extract SSH host key"
    exit 1
fi
echo "✓ Extracted host key: ${HOST_KEY:0:50}..."

echo ""
echo "Step 5: Registering machine with middleware"
echo "--------------------------------------------"

# Set API URL for CLI (HTTP_PORT is set by ci-env.sh from .env)
if [ -n "$HTTP_PORT" ] && [ "$HTTP_PORT" != "80" ]; then
    export SYSTEM_API_URL="http://localhost:${HTTP_PORT}/api"
else
    export SYSTEM_API_URL="http://localhost/api"
fi

echo "Using API URL: $SYSTEM_API_URL"

# Check if required environment variables are set
if [ -z "$SYSTEM_ADMIN_EMAIL" ] || [ -z "$SYSTEM_ADMIN_PASSWORD" ]; then
    echo "Error: SYSTEM_ADMIN_EMAIL or SYSTEM_ADMIN_PASSWORD not set"
    exit 1
fi

# Login to middleware (suppress output to avoid password leakage)
echo "Logging in to middleware..."
if ! _run_cli_command login --email "$SYSTEM_ADMIN_EMAIL" --password "$SYSTEM_ADMIN_PASSWORD" >/dev/null 2>&1; then
    echo "Error: Could not login to middleware"
    echo "Retrying with verbose output..."
    _run_cli_command login --email "$SYSTEM_ADMIN_EMAIL" --password "$SYSTEM_ADMIN_PASSWORD"
    exit 1
fi
echo "✓ Logged in successfully"

# Wait a moment for token to be saved
sleep 0.5

echo ""
echo "Step 4: Updating team vault with SSH private key"
echo "-------------------------------------------------"

# Read and base64-encode the SSH keys (bridge expects base64-encoded keys)
SSH_PRIVATE_KEY_B64=$(base64 -w 0 "$SSH_KEY_FILE")
SSH_PUBLIC_KEY_B64=$(base64 -w 0 "$SSH_PUB_KEY_FILE")

# Get current team vault via GetCompanyTeams
echo "Fetching current team vault..."
TEAMS_RESPONSE=$(_run_cli_command GetCompanyTeams --output json)

if [ $? -ne 0 ]; then
    echo "Error: Could not fetch teams"
    exit 1
fi

# Find the team in the response and extract vault + version
TEAM_DATA=$(echo "$TEAMS_RESPONSE" | jq -r --arg team "$SYSTEM_DEFAULT_TEAM_NAME" '
    .data.result[] | select(.teamName == $team) |
    {vault: .vaultContent, version: .vaultVersion}
')

if [ -z "$TEAM_DATA" ] || [ "$TEAM_DATA" = "null" ]; then
    echo "Error: Could not find team '$SYSTEM_DEFAULT_TEAM_NAME'"
    exit 1
fi

CURRENT_VAULT_STR=$(echo "$TEAM_DATA" | jq -r '.vault')
VAULT_VERSION=$(echo "$TEAM_DATA" | jq -r '.version')

echo "Current vault version: $VAULT_VERSION"

# Parse vault string, update with base64-encoded SSH keys, and convert back to compact JSON
UPDATED_VAULT_STR=$(echo "$CURRENT_VAULT_STR" | jq \
    --arg priv_key "$SSH_PRIVATE_KEY_B64" \
    --arg pub_key "$SSH_PUBLIC_KEY_B64" \
    '.SSH_PRIVATE_KEY = $priv_key | .SSH_PUBLIC_KEY = $pub_key' | jq -c .)

# Call UpdateTeamVault via CLI dynamic endpoint
echo "Updating team vault with runner's SSH key..."
if _run_cli_command UpdateTeamVault \
    --teamName "$SYSTEM_DEFAULT_TEAM_NAME" \
    --teamVault "$UPDATED_VAULT_STR" \
    --vaultVersion "$VAULT_VERSION" 2>&1 | grep -q "Successfully executed"; then
    echo "✓ Team vault updated with SSH private key"
else
    echo "Warning: Could not update team vault. Bridge may not be able to connect."
fi

# Create machine vault JSON
MACHINE_VAULT_JSON=$(jq -n \
    --arg alias "$MACHINE_NAME" \
    --arg ip "$MACHINE_IP" \
    --arg user "$MACHINE_USER" \
    --arg datastore "$MACHINE_DATASTORE" \
    --arg host_entry "$HOST_KEY" \
    '{
        alias: $alias,
        ip: $ip,
        user: $user,
        datastore: $datastore,
        host_entry: $host_entry,
        ssh_password: ""
    }')

# Machine vault created (not printed for security)

# Register machine with middleware
echo ""
echo "Creating machine '$MACHINE_NAME'..."
if _run_cli_command CreateMachine \
    --teamName "${SYSTEM_DEFAULT_TEAM_NAME}" \
    --bridgeName "${SYSTEM_DEFAULT_BRIDGE_NAME}" \
    --machineName "$MACHINE_NAME" \
    --machineVault "$MACHINE_VAULT_JSON"; then
    echo "✓ Machine '$MACHINE_NAME' registered successfully"
else
    echo "Note: Machine may already exist or there was an error"
fi

echo ""
echo "Step 6: Queueing machine setup task"
echo "------------------------------------"

# Fetch company credential and vault data
echo "Fetching company credential..."
COMPANY_RESPONSE=$(_run_cli_command GetCompanyVault --output json)

if [ $? -ne 0 ]; then
    echo "Error: Could not fetch company vault data"
    exit 1
fi

# Extract company credential (becomes COMPANY_ID)
COMPANY_CREDENTIAL=$(echo "$COMPANY_RESPONSE" | jq -r '.data.result[0].companyCredential // .data.result[0].CompanyCredential')
COMPANY_VAULT_STR=$(echo "$COMPANY_RESPONSE" | jq -r '.data.result[0].vaultContent // .data.result[0].VaultContent')

echo "Company credential: ${COMPANY_CREDENTIAL:0:8}..."

# Fetch team vault data
echo "Fetching team vault data..."
TEAMS_RESPONSE=$(_run_cli_command GetCompanyTeams --output json)

if [ $? -ne 0 ]; then
    echo "Error: Could not fetch teams data"
    exit 1
fi

# Find the default team and extract its vault
TEAM_VAULT_STR=$(echo "$TEAMS_RESPONSE" | jq -r --arg team "$SYSTEM_DEFAULT_TEAM_NAME" '
    .data.result[] | select(.teamName == $team or .TeamName == $team) | (.vaultContent // .VaultContent)
')

# Queue a setup task for the localhost machine
# This will install required tools (btrfs-progs, docker, rclone, etc.)
echo "Creating setup queue item with full vault data..."

# Parse vaults and add COMPANY_ID
COMPANY_VAULT_JSON=$(echo "$COMPANY_VAULT_STR" | jq --arg id "$COMPANY_CREDENTIAL" '. + {COMPANY_ID: $id}')
TEAM_VAULT_JSON=$(echo "$TEAM_VAULT_STR" | jq '.')

# Build the setup vault with proper structure
SETUP_VAULT=$(jq -n \
    --arg team "$SYSTEM_DEFAULT_TEAM_NAME" \
    --arg machine "$MACHINE_NAME" \
    --arg ip "$MACHINE_IP" \
    --arg user "$MACHINE_USER" \
    --arg datastore "$MACHINE_DATASTORE" \
    --arg host_entry "$HOST_KEY" \
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

if _run_cli_command CreateQueueItem \
    --teamName "$SYSTEM_DEFAULT_TEAM_NAME" \
    --machineName "$MACHINE_NAME" \
    --bridgeName "${SYSTEM_DEFAULT_BRIDGE_NAME}" \
    --queueVault "$SETUP_VAULT" \
    --priority 1 2>&1 | grep -q "Successfully executed"; then
    echo "✓ Setup task queued successfully"
    echo "  The bridge will process this task and install required dependencies"
else
    echo "Warning: Could not queue setup task. Manual setup may be required."
fi

# Logout
_run_cli_command logout || true

echo ""
echo "============================================"
echo "✓ Localhost machine setup complete"
echo "============================================"
echo ""
echo "Machine Details:"
echo "  Name: $MACHINE_NAME"
echo "  IP: $MACHINE_IP"
echo "  User: $MACHINE_USER"
echo "  Datastore: $MACHINE_DATASTORE"
echo "  SSH Key: $SSH_KEY_FILE"
echo ""
